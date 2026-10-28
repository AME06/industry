#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

class SyncFailure : System.Exception {
    SyncFailure([string] $message) : base($message) {}
}

function Invoke-SyncHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][hashtable] $Headers,
        [AllowNull()][object] $Body
    )
    $parameters = @{
        Method = $Method
        Uri = $Uri
        Headers = $Headers
        MaximumRedirection = 0
        TimeoutSec = 60
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 30 -Compress
        $parameters.ContentType = if ($Method -eq 'PATCH' -or $Uri.Contains('/workitems/$')) {
            'application/json-patch+json'
        } else { 'application/json' }
    }
    try {
        Invoke-RestMethod @parameters
    } catch {
        $status = 'unavailable'
        if ($_.Exception.PSObject.Properties['Response'] -and $null -ne $_.Exception.Response) {
            $response = $_.Exception.Response
            if ($response.PSObject.Properties['StatusCode']) {
                $status = [string][int]$response.StatusCode
            }
        }
        # Never include the request, response body, headers, or original exception.
        throw [SyncFailure]::new("Synchronization HTTP $Method request failed (status $status).")
    }
}

function Get-SyncProperty {
    param([AllowNull()][object] $Value, [string] $Name)
    if ($null -ne $Value -and $Value.PSObject.Properties[$Name]) { $Value.$Name }
}

function Get-SyncPositiveId {
    param([AllowNull()][object] $Value)
    $number = 0
    if (($Value -isnot [string] -and $Value -isnot [int] -and $Value -isnot [long]) -or
        [string]$Value -notmatch '\A[1-9][0-9]*\z' -or
        -not [int]::TryParse([string]$Value, [ref]$number)) {
        throw [SyncFailure]::new('Invalid positive issue or work item number.')
    }
    return $number
}

function Get-SyncPage {
    param([string] $Uri, [hashtable] $Headers)
    # GitHub collections are fetched completely; never infer enrollment from a webhook.
    for ($page = 1; $page -le 10000; $page++) {
        $items = @(Invoke-SyncHttp -Method GET -Uri "${Uri}?per_page=100&page=$page" -Headers $Headers)
        $items
        if ($items.Count -lt 100) { return }
    }
    throw [SyncFailure]::new('GitHub pagination limit exceeded.')
}

function Assert-SyncLabelPermission {
    param([object[]] $Timeline, [string] $Label, [string] $RepositoryUri, [hashtable] $Headers)
    $latest = $null
    foreach ($entry in $Timeline) {
        $timelineEvent = Get-SyncProperty $entry 'event'
        $entryLabel = Get-SyncProperty (Get-SyncProperty $entry 'label') 'name'
        if ($timelineEvent -in @('labeled', 'unlabeled') -and $entryLabel -ieq $Label) {
            $latest = $entry
        }
    }
    if ($null -eq $latest -or (Get-SyncProperty $latest 'event') -ne 'labeled') {
        throw [SyncFailure]::new('Enrollment requires a current maintainer-applied label in the issue timeline.')
    }
    $actor = Get-SyncProperty (Get-SyncProperty $latest 'actor') 'login'
    if ([string]$actor -notmatch '\A[A-Za-z0-9][A-Za-z0-9-]*(?:\[bot\])?\z') {
        throw [SyncFailure]::new('Enrollment label actor is invalid.')
    }
    $permission = Invoke-SyncHttp -Method GET -Uri "$RepositoryUri/collaborators/$([uri]::EscapeDataString($actor))/permission" -Headers $Headers
    if ((Get-SyncProperty $permission 'permission') -notin @('write', 'push', 'maintain', 'admin')) {
        throw [SyncFailure]::new('Enrollment label must be applied by a repository maintainer.')
    }
}

function Get-SyncCanonicalId {
    param([object[]] $Comments, [string] $Organization, [string] $Project, [string] $Source)
    $id = $null
    foreach ($comment in $Comments) {
        $user = Get-SyncProperty $comment 'user'
        if ((Get-SyncProperty $user 'login') -cne 'github-actions[bot]' -or
            (Get-SyncProperty $user 'type') -cne 'Bot' -or
            [string](Get-SyncProperty $user 'id') -ne '41898282') { continue }
        $body = [string](Get-SyncProperty $comment 'body')
        if (-not $body.Contains('azure-boards-sync:')) { continue }
        $markers = [regex]::Matches($body, '<!-- azure-boards-sync:v1 (\{[^\r\n]*\}) -->')
        if ($markers.Count -ne 1 -or
            ([regex]::Matches($body, 'azure-boards-sync:')).Count -ne 1) {
            throw [SyncFailure]::new('Malformed bot-managed Azure Boards mapping.')
        }
        $document = $null
        try {
            # Enumerating JSON properties also rejects duplicate keys, which ConvertFrom-Json replaces.
            $document = [System.Text.Json.JsonDocument]::Parse($markers[0].Groups[1].Value)
            $names = @($document.RootElement.EnumerateObject().Name | Sort-Object)
            $mapping = ConvertFrom-Json -InputObject $markers[0].Groups[1].Value -ErrorAction Stop
        } catch { throw [SyncFailure]::new('Malformed bot-managed Azure Boards mapping.') }
        finally { if ($null -ne $document) { $document.Dispose() } }
        if (($names -join ',') -cne 'id,organization,project,source' -or
            $mapping.organization -isnot [string] -or
            $mapping.project -isnot [string] -or
            $mapping.source -isnot [string] -or
            $mapping.organization -cne $Organization -or
            $mapping.project -cne $Project -or
            $mapping.source -cne $Source -or
            $mapping.id -isnot [long] -and $mapping.id -isnot [int]) {
            throw [SyncFailure]::new('Bot-managed Azure Boards mapping does not match this configuration.')
        }
        $candidate = Get-SyncPositiveId $mapping.id
        if ($null -ne $id -and $candidate -ne $id) { throw [SyncFailure]::new('Conflicting bot-managed Azure Boards mappings.') }
        $id = $candidate
    }
    return $id
}

function Get-SyncWorkItem {
    param([int] $Id, [string] $AzureUri, [hashtable] $Headers, [string] $Project)
    $item = Invoke-SyncHttp -Method GET -Uri "$AzureUri/workitems/${Id}?api-version=7.1" -Headers $Headers
    $fields = Get-SyncProperty $item 'fields'
    if ([string](Get-SyncProperty $fields 'System.TeamProject') -ine $Project -or
        [string](Get-SyncProperty $item 'id') -ne [string]$Id -or
        $null -eq (Get-SyncProperty $item 'rev') -or
        (Get-SyncProperty $fields 'System.WorkItemType') -cnotin @('Task', 'Issue', 'User Story', 'Feature', 'Epic')) {
        throw [SyncFailure]::new('Azure work item identity or project validation failed.')
    }
    return $item
}

function Get-SyncTag {
    param([object] $Item)
    $tags = [string](Get-SyncProperty (Get-SyncProperty $Item 'fields') 'System.Tags')
    return @($tags.Split(';', [StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Assert-SyncOwnership {
    param([object] $Item, [string] $Tag, [switch] $AllowUntagged)
    $tags = @(Get-SyncTag $Item)
    $ownership = @($tags | Where-Object { $_ -imatch '^gh-issue:' })
    if (@($ownership | Where-Object { $_ -cne $Tag }).Count -gt 0 -or
        (-not $AllowUntagged -and $Tag -cnotin $tags)) {
        throw [SyncFailure]::new('Azure work item ownership tag is missing or belongs to another issue.')
    }
}

function Invoke-AzureBoardsSync {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $organization = $env:AZURE_DEVOPS_ORGANIZATION
    $project = $env:AZURE_DEVOPS_PROJECT
    $pat = $env:AZURE_DEVOPS_PAT
    $configured = @($organization, $project, $pat | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($configured -eq 0) {
        if ($env:GITHUB_EVENT_NAME -eq 'workflow_dispatch') {
            return 'Skipped: Azure Boards is not configured; set organization, project, PAT, and open/closed state mappings.'
        }
        return 'Skipped: Azure Boards is not configured.'
    }
    if ($configured -ne 3 -or $organization -notmatch '\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,48}[A-Za-z0-9])?\z' -or
        [string]::IsNullOrWhiteSpace($project) -or $project.Length -gt 128 -or $project -match '[\x00-\x1f\x7f]' -or
        [string]::IsNullOrWhiteSpace($env:AZURE_DEVOPS_OPEN_STATE) -or
        [string]::IsNullOrWhiteSpace($env:AZURE_DEVOPS_CLOSED_STATE) -or
        $env:AZURE_DEVOPS_OPEN_STATE -match '[\x00-\x1f\x7f]' -or
        $env:AZURE_DEVOPS_CLOSED_STATE -match '[\x00-\x1f\x7f]') {
        throw [SyncFailure]::new('Invalid or incomplete Azure Boards configuration; organization, project, PAT, and both state mappings are required.')
    }
    $type = if ([string]::IsNullOrEmpty($env:AZURE_DEVOPS_WORK_ITEM_TYPE)) { 'Task' } else { $env:AZURE_DEVOPS_WORK_ITEM_TYPE }
    if ($type -cnotin @('Task', 'Issue', 'User Story', 'Feature', 'Epic')) {
        throw [SyncFailure]::new('Unsupported Azure Boards work item type.')
    }
    $label = if ([string]::IsNullOrEmpty($env:AZURE_DEVOPS_SYNC_LABEL)) { 'azure-devops' } else { $env:AZURE_DEVOPS_SYNC_LABEL }
    if ([string]::IsNullOrWhiteSpace($label) -or $label -match '[\x00-\x1f\x7f]' -or $label -imatch '^ado:') {
        throw [SyncFailure]::new('Invalid Azure Boards enrollment label.')
    }
    if ($env:GITHUB_SERVER_URL -cne 'https://github.com') { throw [SyncFailure]::new('Only github.com is supported.') }
    if ($env:GITHUB_REPOSITORY -notmatch '\A[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+\z' -or
        [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        throw [SyncFailure]::new('Invalid GitHub repository or missing GitHub token.')
    }
    if ($env:GITHUB_EVENT_NAME -eq 'workflow_dispatch') {
        $issueNumber = Get-SyncPositiveId $env:INPUT_ISSUE_NUMBER
    } elseif ($env:GITHUB_EVENT_NAME -eq 'issues') {
        try {
            $webhook = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -ErrorAction Stop
            $issueNumber = Get-SyncPositiveId $webhook.issue.number
        } catch { throw [SyncFailure]::new('Unable to read a valid issue number from the GitHub event.') }
    } else { throw [SyncFailure]::new('Unsupported GitHub event.') }

    $repositoryUri = "https://api.github.com/repos/$($env:GITHUB_REPOSITORY)"
    $issueUri = "$repositoryUri/issues/$issueNumber"
    $source = "https://github.com/$($env:GITHUB_REPOSITORY)/issues/$issueNumber"
    $githubHeaders = @{
        Authorization = 'Bearer ' + $env:GH_TOKEN
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $issue = Invoke-SyncHttp -Method GET -Uri $issueUri -Headers $githubHeaders
    if ($null -ne (Get-SyncProperty $issue 'pull_request') -or
        [string](Get-SyncProperty $issue 'number') -ne [string]$issueNumber) {
        throw [SyncFailure]::new('GitHub response is not the requested issue.')
    }
    $labels = @((Get-SyncProperty $issue 'labels') | ForEach-Object { [string](Get-SyncProperty $_ 'name') })
    if ($labels -inotcontains $label) { return 'Skipped: issue is not enrolled for Azure Boards synchronization.' }
    $timeline = @(Get-SyncPage -Uri "$issueUri/timeline" -Headers $githubHeaders)
    Assert-SyncLabelPermission -Timeline $timeline -Label $label -RepositoryUri $repositoryUri -Headers $githubHeaders
    $explicitLabels = @($labels | Where-Object { $_ -imatch '^ado:' })
    $explicitId = $null
    if ($explicitLabels.Count -gt 1) { throw [SyncFailure]::new('Multiple Azure Boards linking labels are not allowed.') }
    if ($explicitLabels.Count -eq 1) {
        if ($explicitLabels[0] -cnotmatch '\Aado:([1-9][0-9]*)\z') { throw [SyncFailure]::new('Malformed Azure Boards linking label.') }
        $explicitId = Get-SyncPositiveId $Matches[1]
        Assert-SyncLabelPermission -Timeline $timeline -Label $explicitLabels[0] -RepositoryUri $repositoryUri -Headers $githubHeaders
    }
    $comments = @(Get-SyncPage -Uri "$issueUri/comments" -Headers $githubHeaders)
    $canonicalId = Get-SyncCanonicalId -Comments $comments -Organization $organization -Project $project -Source $source
    if ($null -ne $canonicalId -and $null -ne $explicitId -and $canonicalId -ne $explicitId) {
        throw [SyncFailure]::new('An existing canonical mapping cannot be retargeted.')
    }
    $title = [string](Get-SyncProperty $issue 'title')
    if ([string]::IsNullOrWhiteSpace($title) -or $title.Length -gt 255) { throw [SyncFailure]::new('Issue title must contain 1 to 255 characters.') }
    $state = switch (Get-SyncProperty $issue 'state') {
        'open' { $env:AZURE_DEVOPS_OPEN_STATE }
        'closed' { $env:AZURE_DEVOPS_CLOSED_STATE }
        default { throw [SyncFailure]::new('Unsupported GitHub issue state.') }
    }
    $description = '<p>Source: <a href="' + [System.Net.WebUtility]::HtmlEncode($source) + '">' +
        [System.Net.WebUtility]::HtmlEncode($source) + '</a></p><pre>' +
        [System.Net.WebUtility]::HtmlEncode([string](Get-SyncProperty $issue 'body')) + '</pre>'
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($source))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
    $tag = "gh-issue:$hash"
    $azureUri = "https://dev.azure.com/$([uri]::EscapeDataString($organization))/$([uri]::EscapeDataString($project))/_apis/wit"
    $azureHeaders = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$pat")) }
    $item = $null
    if ($null -ne $canonicalId) {
        $item = Get-SyncWorkItem -Id $canonicalId -AzureUri $azureUri -Headers $azureHeaders -Project $project
        Assert-SyncOwnership -Item $item -Tag $tag
    }
    # Reconciliation precedes every creation, including recovery from a failed GitHub comment.
    $query = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS '$tag'" }
    $result = Invoke-SyncHttp -Method POST -Uri "$azureUri/wiql?api-version=7.1" -Headers $azureHeaders -Body $query
    if ($null -eq $result -or -not $result.PSObject.Properties['workItems'] -or $result.workItems -isnot [array]) {
        throw [SyncFailure]::new('Azure Boards reconciliation returned an invalid response.')
    }
    $reconciledItems = @()
    foreach ($candidate in @(Get-SyncProperty $result 'workItems')) {
        if ($null -eq $candidate) { continue }
        $candidateId = Get-SyncPositiveId (Get-SyncProperty $candidate 'id')
        $candidateItem = Get-SyncWorkItem -Id $candidateId -AzureUri $azureUri -Headers $azureHeaders -Project $project
        if ($tag -cin @(Get-SyncTag $candidateItem)) {
            Assert-SyncOwnership -Item $candidateItem -Tag $tag
            $reconciledItems += $candidateItem
        }
    }
    if ($reconciledItems.Count -gt 1) { throw [SyncFailure]::new('Multiple Azure work items have the source ownership tag.') }
    $targetId = if ($null -ne $canonicalId) { $canonicalId } else { $explicitId }
    if ($reconciledItems.Count -eq 1) {
        if ($null -ne $targetId -and $targetId -ne $reconciledItems[0].id) { throw [SyncFailure]::new('Azure Boards mapping conflicts with reconciliation.') }
        $item = $reconciledItems[0]
    } elseif ($null -eq $item -and $null -ne $explicitId) {
        $item = Get-SyncWorkItem -Id $explicitId -AzureUri $azureUri -Headers $azureHeaders -Project $project
        Assert-SyncOwnership -Item $item -Tag $tag -AllowUntagged
    }
    $patch = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = $title }
        @{ op = 'add'; path = '/fields/System.Description'; value = $description }
        @{ op = 'add'; path = '/fields/System.State'; value = $state }
    )
    if ($null -eq $item) {
        $patch += @{ op = 'add'; path = '/fields/System.Tags'; value = $tag }
        $created = Invoke-SyncHttp -Method POST -Uri "$azureUri/workitems/`$$([uri]::EscapeDataString($type))?api-version=7.1" -Headers $azureHeaders -Body $patch
        $id = Get-SyncPositiveId (Get-SyncProperty $created 'id')
    } else {
        $id = Get-SyncPositiveId $item.id
        $patch = @(@{ op = 'test'; path = '/rev'; value = $item.rev }) + $patch
        $tags = @(Get-SyncTag $item)
        if ($tag -cnotin $tags) {
            $patch += @{ op = 'add'; path = '/fields/System.Tags'; value = (($tags + $tag) -join '; ') }
        }
        $null = Invoke-SyncHttp -Method PATCH -Uri "$azureUri/workitems/${id}?api-version=7.1" -Headers $azureHeaders -Body $patch
    }
    if ($null -eq $canonicalId) {
        $url = "https://dev.azure.com/$([uri]::EscapeDataString($organization))/$([uri]::EscapeDataString($project))/_workitems/edit/$id"
        $mapping = ConvertTo-Json -InputObject ([ordered]@{ organization = $organization; project = $project; id = $id; source = $source }) -Compress
        $body = @{ body = "Azure Boards work item: $url`n`n<!-- azure-boards-sync:v1 $mapping -->" }
        $null = Invoke-SyncHttp -Method POST -Uri "$issueUri/comments" -Headers $githubHeaders -Body $body
    }
    return "Synchronized issue #$issueNumber to Azure Boards work item #$id."
}

function Invoke-SyncEntryPoint {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    try {
        [Console]::Out.WriteLine([string](Invoke-AzureBoardsSync))
        return 0
    }
    catch {
        # Errors from parsing, the filesystem, or the runtime must not disclose input or secrets.
        if ($_.Exception -is [SyncFailure]) {
            [Console]::Error.WriteLine($_.Exception.Message)
        } else {
            [Console]::Error.WriteLine('Azure Boards synchronization failed. Check configuration, maintainer labels, mapping integrity, and service availability.')
        }
        return 1
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-SyncEntryPoint)
}
