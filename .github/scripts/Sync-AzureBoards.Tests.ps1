#requires -Version 7.2
BeforeAll {
    . "$PSScriptRoot/Sync-AzureBoards.ps1"
    $script:environmentNames = @(
        'AZURE_DEVOPS_ORGANIZATION', 'AZURE_DEVOPS_PROJECT', 'AZURE_DEVOPS_PAT',
        'AZURE_DEVOPS_WORK_ITEM_TYPE', 'AZURE_DEVOPS_SYNC_LABEL',
        'AZURE_DEVOPS_OPEN_STATE', 'AZURE_DEVOPS_CLOSED_STATE', 'GH_TOKEN',
        'GITHUB_SERVER_URL', 'GITHUB_REPOSITORY', 'GITHUB_EVENT_NAME',
        'GITHUB_EVENT_PATH', 'INPUT_ISSUE_NUMBER'
    )
    $script:savedEnvironment = @{}
    foreach ($environmentName in $script:environmentNames) {
        $script:savedEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName)
    }
    $script:source = 'https://github.com/example/repository/issues/17'
    $script:tag = 'gh-issue:' + [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($script:source))
    ).ToLowerInvariant()

    function Get-TestLabelEvent {
        param([string] $Label = 'azure-devops', [string] $Actor = 'maintainer', [string] $EventKind = 'labeled')
        [pscustomobject]@{ event = $EventKind; label = [pscustomobject]@{ name = $Label }; actor = [pscustomobject]@{ login = $Actor } }
    }

    function Get-TestWorkItem {
        param([int] $Id = 101, [string] $Tags = $script:tag, [string] $Project = 'Test Project')
        [pscustomobject]@{
            id = $Id
            rev = 4
            fields = [pscustomobject]@{
                'System.TeamProject' = $Project
                'System.WorkItemType' = 'Task'
                'System.Tags' = $Tags
            }
        }
    }

    function Get-TestComment {
        param([int] $Id = 101)
        $mapping = @{ organization = 'example-org'; project = 'Test Project'; id = $Id; source = $script:source } | ConvertTo-Json -Compress
        [pscustomobject]@{
            user = [pscustomobject]@{ login = 'github-actions[bot]'; type = 'Bot'; id = 41898282 }
            body = "Azure Boards work item: https://dev.azure.com/example-org/Test%20Project/_workitems/edit/$Id`n`n<!-- azure-boards-sync:v1 $mapping -->"
        }
    }
}

AfterAll {
    foreach ($environmentName in $script:environmentNames) {
        [Environment]::SetEnvironmentVariable($environmentName, $script:savedEnvironment[$environmentName])
    }
}

Describe 'Issue to Azure Boards synchronization (offline)' {
    BeforeEach {
        foreach ($environmentName in $script:environmentNames) { [Environment]::SetEnvironmentVariable($environmentName, $null) }
        $env:AZURE_DEVOPS_ORGANIZATION = 'example-org'
        $env:AZURE_DEVOPS_PROJECT = 'Test Project'
        $env:AZURE_DEVOPS_PAT = 'test-pat-not-a-credential'
        $env:AZURE_DEVOPS_OPEN_STATE = 'Ready'
        $env:AZURE_DEVOPS_CLOSED_STATE = 'Finished'
        $env:GH_TOKEN = 'test-token-not-a-credential'
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_REPOSITORY = 'example/repository'
        $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
        $env:INPUT_ISSUE_NUMBER = '17'
        $script:issue = [pscustomobject]@{
            number = 17; title = 'Current issue'; body = 'Current body'; state = 'open'
            labels = @([pscustomobject]@{ name = 'azure-devops' })
        }
        $script:timelinePages = @{ 1 = @(Get-TestLabelEvent) }
        $script:commentPages = @{ 1 = @() }
        $script:permissions = @{ maintainer = 'write'; outsider = 'read' }
        $script:workItems = @{}
        $script:queryIds = @()
        $script:requests = [Collections.Generic.List[object]]::new()
        $script:failComment = $false
        $script:failEndpoint = ''
        $script:failRevision = $false
        Mock Invoke-SyncHttp {
            param($Method, $Uri, $Headers, $Body)
            $script:requests.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $Body })
            if ($script:failEndpoint -and $Uri.Contains($script:failEndpoint)) { throw 'Synchronization HTTP request failed (status 403).' }
            if ($Uri -eq 'https://api.github.com/repos/example/repository/issues/17' -and $Method -eq 'GET') { return $script:issue }
            if ($Uri -match '/timeline\?per_page=100&page=(\d+)$') {
                if ($script:timelinePages.ContainsKey([int]$Matches[1])) { return $script:timelinePages[[int]$Matches[1]] }
                return @()
            }
            if ($Uri -match '/collaborators/([^/]+)/permission$') {
                return [pscustomobject]@{ permission = $script:permissions[$Matches[1]] }
            }
            if ($Uri -match '/comments\?per_page=100&page=(\d+)$' -and $Method -eq 'GET') {
                if ($script:commentPages.ContainsKey([int]$Matches[1])) { return $script:commentPages[[int]$Matches[1]] }
                return @()
            }
            if ($Uri.EndsWith('/comments') -and $Method -eq 'POST') {
                if ($script:failComment) { throw 'Synchronization HTTP request failed (status 503).' }
                $script:commentPages[1] = @([pscustomobject]@{
                    user = [pscustomobject]@{ login = 'github-actions[bot]'; type = 'Bot'; id = 41898282 }
                    body = $Body.body
                })
                return [pscustomobject]@{ id = 55 }
            }
            if ($Uri.EndsWith('/wiql?api-version=7.1') -and $Method -eq 'POST') {
                return [pscustomobject]@{ workItems = @($script:queryIds | ForEach-Object { [pscustomobject]@{ id = $_ } }) }
            }
            if ($Uri -match '/workitems/(\d+)\?api-version=7\.1$') {
                $itemId = [int]$Matches[1]
                if (-not $script:workItems.ContainsKey($itemId)) { throw 'Synchronization HTTP request failed (status 404).' }
                if ($Method -eq 'GET') { return $script:workItems[$itemId] }
                if ($Method -eq 'PATCH') {
                    if ($script:failRevision) { throw 'Synchronization HTTP request failed (status 412).' }
                    return $script:workItems[$itemId]
                }
            }
            if ($Uri -match '/workitems/\$[^?]+\?api-version=7\.1$' -and $Method -eq 'POST') {
                $script:workItems[101] = Get-TestWorkItem
                $script:queryIds = @(101)
                return $script:workItems[101]
            }
            throw 'Unexpected mocked HTTP request.'
        }
        # A router mistake must never fall back to a real network call.
        Mock Invoke-RestMethod { throw 'Network access is forbidden in tests.' }
    }

    It 'creates one Task using fresh GitHub data, mapped state, ownership, and a canonical comment' {
        Invoke-AzureBoardsSync | Should -Be 'Synchronized issue #17 to Azure Boards work item #101.'
        $script:requests[0].Uri | Should -Be 'https://api.github.com/repos/example/repository/issues/17'
        $script:requests[0].Headers.Authorization | Should -Be ('Bearer ' + $env:GH_TOKEN)
        $create = @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/workitems/\$' })
        $create.Count | Should -Be 1
        $create[0].Uri | Should -Be 'https://dev.azure.com/example-org/Test%20Project/_apis/wit/workitems/$Task?api-version=7.1'
        ($create[0].Body | Where-Object path -eq '/fields/System.Title').value | Should -Be 'Current issue'
        ($create[0].Body | Where-Object path -eq '/fields/System.State').value | Should -Be 'Ready'
        ($create[0].Body | Where-Object path -eq '/fields/System.Tags').value | Should -Be $script:tag
        $script:requests.Uri -join ';' | Should -Not -Match 'bypassRules'
        $query = $script:requests | Where-Object { $_.Uri -match '/wiql\?' }
        $query.Body.query | Should -Be "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS '$script:tag'"
        $script:commentPages[1][0].body | Should -Match 'https://dev.azure.com/example-org/Test%20Project/_workitems/edit/101'
        Get-SyncCanonicalId $script:commentPages[1] 'example-org' 'Test Project' $script:source | Should -Be 101
        Should -Invoke Invoke-RestMethod -Times 0
        @($script:requests | Where-Object { $_.Method -eq 'PATCH' -and $_.Uri -like '*api.github.com*' }).Count | Should -Be 0
    }

    It 'maps <Operation> to the configured state and updates with a revision test' -TestCases @(
        @{ Operation = 'edit'; State = 'open'; Expected = 'Ready' }
        @{ Operation = 'close'; State = 'closed'; Expected = 'Finished' }
        @{ Operation = 'reopen'; State = 'open'; Expected = 'Ready' }
    ) {
        param($Operation, $State, $Expected)
        $script:issue.state = $State
        $script:issue.title = "$Operation title"
        $script:commentPages[1] = @(Get-TestComment)
        $script:workItems[101] = Get-TestWorkItem
        Invoke-AzureBoardsSync | Should -Match '^Synchronized'
        $update = $script:requests | Where-Object Method -eq 'PATCH'
        $update.Body[0].op | Should -Be 'test'
        $update.Body[0].path | Should -Be '/rev'
        $update.Body[0].value | Should -Be 4
        ($update.Body | Where-Object path -eq '/fields/System.State').value | Should -Be $Expected
        ($update.Body | Where-Object path -eq '/fields/System.Title').value | Should -Be "$Operation title"
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/workitems/\$|/comments$' }).Count | Should -Be 0
    }

    It 'uses the event file only for the issue number, never webhook content or sender' {
        $env:GITHUB_EVENT_NAME = 'issues'
        $env:GITHUB_EVENT_PATH = 'not-a-real-event-path'
        $env:INPUT_ISSUE_NUMBER = '999'
        Mock Get-Content {
            '{"issue":{"number":17,"title":"stale","state":"closed","labels":[]},"repository":{"full_name":"attacker/repo"},"sender":{"login":"outsider"}}'
        } -ParameterFilter { $LiteralPath -eq 'not-a-real-event-path' -and $Raw }
        Invoke-AzureBoardsSync | Should -Match '^Synchronized'
        Should -Invoke Get-Content -Times 1 -Exactly
        ($script:requests | Where-Object { $_.Uri -match '/workitems/\$' }).Body[0].value | Should -Be 'Current issue'
    }

    It 'skips an opted-out issue without timeline, comments, or Azure access' {
        $script:issue.labels = @([pscustomobject]@{ name = 'ado:101' })
        Invoke-AzureBoardsSync | Should -Match '^Skipped: issue is not enrolled'
        $script:requests.Count | Should -Be 1
    }

    It 'requires latest sync-label addition by a maintainer even for an edit' {
        $script:timelinePages[1] = @(
            Get-TestLabelEvent
            Get-TestLabelEvent -EventKind 'unlabeled'
            Get-TestLabelEvent -Actor 'outsider'
        )
        { Invoke-AzureBoardsSync } | Should -Throw '*repository maintainer*'
        @($script:requests | Where-Object Uri -like '*dev.azure.com*').Count | Should -Be 0
    }

    It 'accepts maintainer permission <Permission>' -TestCases @(
        @{ Permission = 'write' }; @{ Permission = 'push' }; @{ Permission = 'maintain' }; @{ Permission = 'admin' }
    ) {
        param($Permission)
        $script:permissions.maintainer = $Permission
        Invoke-AzureBoardsSync | Should -Match '^Synchronized'
    }

    It 'rejects current labels without timeline evidence or after a latest removal' -TestCases @(
        @{ Removed = $false }; @{ Removed = $true }
    ) {
        param($Removed)
        $script:timelinePages[1] = if ($Removed) { @(Get-TestLabelEvent -EventKind 'unlabeled') } else { @() }
        { Invoke-AzureBoardsSync } | Should -Throw '*current maintainer-applied label*'
    }

    It 'validates explicit adoption separately and preserves unrelated tags' {
        $script:issue.labels += [pscustomobject]@{ name = 'ado:88' }
        $script:timelinePages[1] += Get-TestLabelEvent -Label 'ado:88'
        $script:workItems[88] = Get-TestWorkItem -Id 88 -Tags 'product; customer:blue'
        Invoke-AzureBoardsSync | Should -Match '#88'
        $update = $script:requests | Where-Object Method -eq 'PATCH'
        $update.Uri | Should -Match '/workitems/88\?'
        $update.Body[0].path | Should -Be '/rev'
        ($update.Body | Where-Object path -eq '/fields/System.Tags').value | Should -Be "product; customer:blue; $script:tag"
    }

    It 'rejects explicit labels added by public authors' {
        $script:issue.labels += [pscustomobject]@{ name = 'ado:88' }
        $script:timelinePages[1] += Get-TestLabelEvent -Label 'ado:88' -Actor 'outsider'
        { Invoke-AzureBoardsSync } | Should -Throw '*repository maintainer*'
        @($script:requests | Where-Object Uri -like '*dev.azure.com*').Count | Should -Be 0
    }

    It 'rejects malformed or multiple linking labels: <Labels>' -TestCases @(
        @{ Labels = @('ado:0') }; @{ Labels = @('ado:-1') }; @{ Labels = @('ado:01') }
        @{ Labels = @('ado:2147483648') }; @{ Labels = @('ado:1; bypass') }
        @{ Labels = @('ado:1', 'ado:2') }; @{ Labels = @('ADO:1') }; @{ Labels = @("ado:17`n") }
    ) {
        param($Labels)
        $script:issue.labels += @($Labels | ForEach-Object { [pscustomobject]@{ name = $_ } })
        { Invoke-AzureBoardsSync } | Should -Throw
        @($script:requests | Where-Object Uri -like '*dev.azure.com*').Count | Should -Be 0
    }

    It 'rejects retargeting a canonical mapping via an authorized label' {
        $script:commentPages[1] = @(Get-TestComment)
        $script:issue.labels += [pscustomobject]@{ name = 'ado:88' }
        $script:timelinePages[1] += Get-TestLabelEvent -Label 'ado:88'
        { Invoke-AzureBoardsSync } | Should -Throw '*cannot be retargeted*'
    }

    It 'reconciles an earlier creation after a GitHub comment failure without creating twice' {
        $script:failComment = $true
        { Invoke-AzureBoardsSync } | Should -Throw '*status 503*'
        $script:failComment = $false
        Invoke-AzureBoardsSync | Should -Match '^Synchronized'
        Invoke-AzureBoardsSync | Should -Match '^Synchronized'
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/workitems/\$' }).Count | Should -Be 1
        @($script:requests | Where-Object Method -eq 'PATCH').Count | Should -Be 2
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri.EndsWith('/comments') }).Count | Should -Be 2
    }

    It 'ignores substring tag matches and creates an exact ownership tag' {
        $script:queryIds = @(88)
        $script:workItems[88] = Get-TestWorkItem -Id 88 -Tags "$script:tag-suffix"
        Invoke-AzureBoardsSync | Should -Match '#101'
    }

    It 'fails on duplicate exact ownership tags instead of selecting arbitrarily' {
        $script:queryIds = @(88, 89)
        $script:workItems[88] = Get-TestWorkItem -Id 88
        $script:workItems[89] = Get-TestWorkItem -Id 89
        { Invoke-AzureBoardsSync } | Should -Throw '*Multiple Azure work items*'
        @($script:requests | Where-Object Method -eq 'PATCH').Count | Should -Be 0
    }

    It 'fails on explicit versus reconciled mapping conflicts' {
        $script:queryIds = @(89)
        $script:workItems[89] = Get-TestWorkItem -Id 89
        $script:issue.labels += [pscustomobject]@{ name = 'ado:88' }
        $script:timelinePages[1] += Get-TestLabelEvent -Label 'ado:88'
        { Invoke-AzureBoardsSync } | Should -Throw '*conflicts with reconciliation*'
    }

    It 'fails on canonical versus reconciled mapping conflicts' {
        $script:commentPages[1] = @(Get-TestComment)
        $script:workItems[101] = Get-TestWorkItem
        $script:queryIds = @(88)
        $script:workItems[88] = Get-TestWorkItem -Id 88
        { Invoke-AzureBoardsSync } | Should -Throw '*conflicts with reconciliation*'
        @($script:requests | Where-Object Method -eq 'PATCH').Count | Should -Be 0
    }

    It 'fails closed on an invalid reconciliation response rather than creating' {
        Mock Invoke-SyncHttp { [pscustomobject]@{ unexpected = 'response' } } -ParameterFilter { $Uri -like '*/wiql?api-version=7.1' }
        { Invoke-AzureBoardsSync } | Should -Throw '*invalid response*'
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/workitems/\$' }).Count | Should -Be 0
    }

    It 'fails on a forbidden explicit work item without creating a fallback' {
        $script:issue.labels += [pscustomobject]@{ name = 'ado:88' }
        $script:timelinePages[1] += Get-TestLabelEvent -Label 'ado:88'
        $script:failEndpoint = '/workitems/88'
        { Invoke-AzureBoardsSync } | Should -Throw '*status 403*'
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/workitems/\$' }).Count | Should -Be 0
    }

    It 'does not publish a link when Azure creation fails' {
        $script:failEndpoint = '/workitems/$Task'
        { Invoke-AzureBoardsSync } | Should -Throw '*status 403*'
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri.EndsWith('/comments') }).Count | Should -Be 0
    }

    It 'never recreates a missing canonical or explicit work item (<Canonical>)' -TestCases @(
        @{ Canonical = $true }; @{ Canonical = $false }
    ) {
        param($Canonical)
        if ($Canonical) { $script:commentPages[1] = @(Get-TestComment) }
        else {
            $script:issue.labels += [pscustomobject]@{ name = 'ado:101' }
            $script:timelinePages[1] += Get-TestLabelEvent -Label 'ado:101'
        }
        { Invoke-AzureBoardsSync } | Should -Throw '*status 404*'
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/workitems/\$' }).Count | Should -Be 0
    }

    It 'rejects canonical items whose ownership tag was lost' {
        $script:commentPages[1] = @(Get-TestComment)
        $script:workItems[101] = Get-TestWorkItem -Tags 'unrelated'
        { Invoke-AzureBoardsSync } | Should -Throw '*ownership tag*'
    }

    It 'rejects adopted items belonging to another issue, including mixed ownership tags' -TestCases @(
        @{ Tags = 'gh-issue:other' }; @{ Tags = 'mixed' }
    ) {
        param($Tags)
        $script:issue.labels += [pscustomobject]@{ name = 'ado:88' }
        $script:timelinePages[1] += Get-TestLabelEvent -Label 'ado:88'
        if ($Tags -eq 'mixed') { $Tags = "$script:tag; gh-issue:other" }
        $script:workItems[88] = Get-TestWorkItem -Id 88 -Tags $Tags
        { Invoke-AzureBoardsSync } | Should -Throw '*ownership tag*'
    }

    It 'verifies project membership of retrieved work items' {
        $script:queryIds = @(88)
        $script:workItems[88] = Get-TestWorkItem -Id 88 -Project 'Other Project'
        { Invoke-AzureBoardsSync } | Should -Throw '*project validation*'
    }

    It 'excludes Bug items from existing links too' {
        $script:commentPages[1] = @(Get-TestComment)
        $script:workItems[101] = Get-TestWorkItem
        $script:workItems[101].fields.'System.WorkItemType' = 'Bug'
        { Invoke-AzureBoardsSync } | Should -Throw '*validation*'
    }

    It 'does not clobber concurrently changed work items or create a fallback' {
        $script:queryIds = @(101)
        $script:workItems[101] = Get-TestWorkItem
        $script:failRevision = $true
        { Invoke-AzureBoardsSync } | Should -Throw '*status 412*'
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/workitems/\$|/comments$' }).Count | Should -Be 0
    }

    It 'fails closed for GitHub/Azure HTTP failures at <Endpoint>' -TestCases @(
        @{ Endpoint = '/issues/17' }; @{ Endpoint = '/timeline' }; @{ Endpoint = '/permission' }
        @{ Endpoint = '/comments' }; @{ Endpoint = '/wiql' }; @{ Endpoint = '/workitems/101?' }
    ) {
        param($Endpoint)
        $script:failEndpoint = $Endpoint
        $script:commentPages[1] = @(Get-TestComment)
        $script:workItems[101] = Get-TestWorkItem
        { Invoke-AzureBoardsSync } | Should -Throw '*status 403*'
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/workitems/\$' }).Count | Should -Be 0
    }

    It 'escapes untrusted issue HTML and preserves special title characters' {
        $script:issue.title = 'Quotes " & emoji ' + [char]0x2603
        $script:issue.body = "<script>alert(`"x`")</script>&`nsecond line"
        Invoke-AzureBoardsSync | Should -Match '^Synchronized'
        $patch = ($script:requests | Where-Object { $_.Uri -match '/workitems/\$' }).Body
        ($patch | Where-Object path -eq '/fields/System.Title').value | Should -Be $script:issue.title
        $description = ($patch | Where-Object path -eq '/fields/System.Description').value
        $description | Should -Not -Match '<script>'
        $description | Should -Match '&lt;script&gt;alert\(&quot;x&quot;\)&lt;/script&gt;&amp;'
        $description | Should -Match '<a href="https://github.com/example/repository/issues/17">'
    }

    It 'does not trust an issue-supplied source URL' {
        $script:issue | Add-Member html_url 'https://attacker.example/issues/17'
        Invoke-AzureBoardsSync | Should -Match '^Synchronized'
        $patch = ($script:requests | Where-Object { $_.Uri -match '/workitems/\$' }).Body
        ($patch | Where-Object path -eq '/fields/System.Description').value | Should -Not -Match 'attacker'
        ($patch | Where-Object path -eq '/fields/System.Tags').value | Should -Be $script:tag
    }

    It 'rejects overlong issue titles without writes' {
        $script:issue.title = 'x' * 256
        { Invoke-AzureBoardsSync } | Should -Throw '*255*'
        @($script:requests | Where-Object Method -ne 'GET').Count | Should -Be 0
    }

    It 'paginates both timelines and comments before making decisions' {
        $script:timelinePages[1] = @(1..100 | ForEach-Object { Get-TestLabelEvent })
        $script:timelinePages[2] = @(Get-TestLabelEvent -Actor 'outsider')
        { Invoke-AzureBoardsSync } | Should -Throw '*repository maintainer*'
        $script:timelinePages[2] = @(Get-TestLabelEvent)
        $script:commentPages[1] = @(1..100 | ForEach-Object {
            [pscustomobject]@{ user = [pscustomobject]@{ login = 'outsider'; type = 'User'; id = 1 }; body = 'ordinary' }
        })
        $script:commentPages[2] = @(Get-TestComment)
        $script:workItems[101] = Get-TestWorkItem
        Invoke-AzureBoardsSync | Should -Match '^Synchronized'
        @($script:requests | Where-Object Uri -like '*comments?per_page=100&page=2').Count | Should -Be 1
        @($script:requests | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/workitems/\$|/comments$' }).Count | Should -Be 0
    }

    It 'ignores spoofed bot mappings with an incorrect <Field>' -TestCases @(
        @{ Field = 'id'; Value = 1 }; @{ Field = 'type'; Value = 'User' }; @{ Field = 'login'; Value = 'outsider' }
    ) {
        param($Field, $Value)
        $spoof = Get-TestComment -Id 88
        $spoof.user.$Field = $Value
        $script:commentPages[1] = @($spoof)
        Invoke-AzureBoardsSync | Should -Match '#101'
    }

    It 'rejects malformed or mismatched genuine bot mappings: <Case>' -TestCases @(
        @{ Case = 'json' }; @{ Case = 'version' }; @{ Case = 'organization' }; @{ Case = 'project' }
        @{ Case = 'source' }; @{ Case = 'id' }; @{ Case = 'string-id' }; @{ Case = 'extra' }; @{ Case = 'multiple-markers' }
        @{ Case = 'duplicate-key' }; @{ Case = 'array-value' }
    ) {
        param($Case)
        $comment = Get-TestComment
        switch ($Case) {
            'json' { $comment.body = '<!-- azure-boards-sync:v1 {bad} -->' }
            'version' { $comment.body = '<!-- azure-boards-sync:v2 {} -->' }
            'organization' { $comment.body = $comment.body.Replace('"example-org"', '"other-org"') }
            'project' { $comment.body = $comment.body.Replace('"Test Project"', '"Other Project"') }
            'source' { $comment.body = $comment.body.Replace('/issues/17', '/issues/18') }
            'id' { $comment.body = $comment.body.Replace('"id":101', '"id":0') }
            'string-id' { $comment.body = $comment.body.Replace('"id":101', '"id":"101"') }
            'extra' { $comment.body = $comment.body.Replace('{"', '{"extra":true,"') }
            'multiple-markers' { $comment.body += $comment.body }
            'duplicate-key' { $comment.body = $comment.body.Replace('"id":101', '"id":88,"id":101') }
            'array-value' { $comment.body = $comment.body.Replace('"organization":"example-org"', '"organization":["example-org"]') }
        }
        $script:commentPages[1] = @($comment)
        { Invoke-AzureBoardsSync } | Should -Throw
        @($script:requests | Where-Object Uri -like '*dev.azure.com*').Count | Should -Be 0
    }

    It 'rejects conflicting canonical comments' {
        $script:commentPages[1] = @((Get-TestComment -Id 88), (Get-TestComment -Id 89))
        { Invoke-AzureBoardsSync } | Should -Throw '*Conflicting*'
    }

    It 'skips intentionally unconfigured automation and explains manual setup' {
        $env:AZURE_DEVOPS_ORGANIZATION = $null
        $env:AZURE_DEVOPS_PROJECT = $null
        $env:AZURE_DEVOPS_PAT = $null
        Invoke-AzureBoardsSync | Should -Match 'not configured; set organization, project, PAT'
        $env:GITHUB_EVENT_NAME = 'issues'
        Invoke-AzureBoardsSync | Should -Be 'Skipped: Azure Boards is not configured.'
        $script:requests.Count | Should -Be 0
    }

    It 'rejects invalid or incomplete configuration: <Name>' -TestCases @(
        @{ Name = 'AZURE_DEVOPS_ORGANIZATION'; Value = '' }
        @{ Name = 'AZURE_DEVOPS_PAT'; Value = '' }
        @{ Name = 'AZURE_DEVOPS_PROJECT'; Value = '' }
        @{ Name = 'AZURE_DEVOPS_OPEN_STATE'; Value = '' }
        @{ Name = 'AZURE_DEVOPS_CLOSED_STATE'; Value = '' }
        @{ Name = 'AZURE_DEVOPS_ORGANIZATION'; Value = 'https://evil.example' }
        @{ Name = 'AZURE_DEVOPS_ORGANIZATION'; Value = 'host/path' }
        @{ Name = 'AZURE_DEVOPS_ORGANIZATION'; Value = "example-org`n" }
        @{ Name = 'AZURE_DEVOPS_PROJECT'; Value = "bad`nproject" }
        @{ Name = 'AZURE_DEVOPS_WORK_ITEM_TYPE'; Value = 'Bug' }
        @{ Name = 'AZURE_DEVOPS_WORK_ITEM_TYPE'; Value = 'Task/path' }
        @{ Name = 'AZURE_DEVOPS_SYNC_LABEL'; Value = 'ado:1' }
        @{ Name = 'GITHUB_SERVER_URL'; Value = 'https://enterprise.example' }
        @{ Name = 'GITHUB_SERVER_URL'; Value = 'https://github.com.evil.example' }
        @{ Name = 'GITHUB_REPOSITORY'; Value = 'owner/repo/../../evil' }
        @{ Name = 'GH_TOKEN'; Value = '' }
        @{ Name = 'GITHUB_EVENT_NAME'; Value = 'pull_request' }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = '0' }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = '1/../../2' }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = '017' }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = ' 17' }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = '17 ' }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = "17`n" }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = "17`r`n" }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = '+17' }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = '17.0' }
        @{ Name = 'INPUT_ISSUE_NUMBER'; Value = '2147483648' }
    ) {
        param($Name, $Value)
        [Environment]::SetEnvironmentVariable($Name, $Value)
        { Invoke-AzureBoardsSync } | Should -Throw
        $script:requests.Count | Should -Be 0
    }

    It 'supports custom enrollment label and safely encoded work item types' {
        $env:AZURE_DEVOPS_WORK_ITEM_TYPE = 'User Story'
        $env:AZURE_DEVOPS_SYNC_LABEL = 'boards ready'
        $script:issue.labels = @([pscustomobject]@{ name = 'boards ready' })
        $script:timelinePages[1] = @(Get-TestLabelEvent -Label 'boards ready')
        Invoke-AzureBoardsSync | Should -Match '^Synchronized'
        ($script:requests | Where-Object { $_.Uri -match '/workitems/\$' }).Uri | Should -Match '/workitems/\$User%20Story\?api-version=7.1$'
    }

    It 'rejects pull requests and mismatched issue responses' -TestCases @(
        @{ PullRequest = $true }; @{ PullRequest = $false }
    ) {
        param($PullRequest)
        if ($PullRequest) { $script:issue | Add-Member pull_request ([pscustomobject]@{ url = 'untrusted' }) }
        else { $script:issue.number = 18 }
        { Invoke-AzureBoardsSync } | Should -Throw '*not the requested issue*'
        $script:requests.Count | Should -Be 1
    }

    It 'sanitizes invalid webhook parsing errors' {
        $env:GITHUB_EVENT_NAME = 'issues'
        $env:GITHUB_EVENT_PATH = 'secret-looking-path'
        Mock Get-Content { throw 'sensitive filesystem contents' }
        { Invoke-AzureBoardsSync } | Should -Throw 'Unable to read a valid issue number from the GitHub event.'
        $script:requests.Count | Should -Be 0
    }

    It 'does not fall back to the webhook when dispatch input is absent' {
        $env:INPUT_ISSUE_NUMBER = ''
        $env:GITHUB_EVENT_PATH = 'not-a-real-event-path'
        Mock Get-Content { '{"issue":{"number":17}}' }
        { Invoke-AzureBoardsSync } | Should -Throw '*Invalid positive*'
        Should -Invoke Get-Content -Times 0
        $script:requests.Count | Should -Be 0
    }

    It 'rejects non-scalar webhook issue numbers' {
        $env:GITHUB_EVENT_NAME = 'issues'
        $env:GITHUB_EVENT_PATH = 'not-a-real-event-path'
        Mock Get-Content { '{"issue":{"number":[17]}}' }
        { Invoke-AzureBoardsSync } | Should -Throw '*valid issue number*'
        $script:requests.Count | Should -Be 0
    }
}

Describe 'Credential-safe HTTP transport (offline)' {
    It 'disables redirects and serializes JSON patch arrays as arrays' {
        Mock Invoke-RestMethod { [pscustomobject]@{ id = 1 } }
        $patch = @(@{ op = 'test'; path = '/rev'; value = 2 })
        $null = Invoke-SyncHttp -Method PATCH -Uri 'https://dev.azure.com/org/project/_apis/wit/workitems/1?api-version=7.1' -Headers @{ Authorization = 'test' } -Body $patch
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $MaximumRedirection -eq 0 -and $TimeoutSec -eq 60 -and $ContentType -eq 'application/json-patch+json' -and
            $Body.StartsWith('[') -and $Body.EndsWith(']') -and $ErrorAction -eq 'Stop'
        }
    }

    It 'uses JSON patch content type for creation and plain JSON for WIQL' {
        Mock Invoke-RestMethod {}
        $null = Invoke-SyncHttp -Method POST -Uri 'https://dev.azure.com/org/project/_apis/wit/workitems/$Task?api-version=7.1' -Headers @{} -Body @(@{ op = 'add'; path = '/fields/System.Title'; value = ('a " & ' + [char]0x2603) })
        $null = Invoke-SyncHttp -Method POST -Uri 'https://dev.azure.com/org/project/_apis/wit/wiql?api-version=7.1' -Headers @{} -Body @{ query = 'SELECT' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $MaximumRedirection -eq 0 -and $ContentType -eq 'application/json-patch+json' -and
            (($Body | ConvertFrom-Json)[0].value -eq ('a " & ' + [char]0x2603))
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $MaximumRedirection -eq 0 -and $ContentType -eq 'application/json' -and ($Body | ConvertFrom-Json).query -eq 'SELECT'
        }
    }

    It 'never exposes transport exception details' {
        Mock Invoke-RestMethod { throw 'sensitive Authorization header and response body' }
        { Invoke-SyncHttp -Method GET -Uri 'https://api.github.com/test' -Headers @{ Authorization = 'sensitive' } } |
            Should -Throw 'Synchronization HTTP GET request failed (status unavailable).'
    }

    It 'reports only the status for HTTP failures including redirects' -TestCases @(
        @{ Status = 302 }; @{ Status = 401 }; @{ Status = 403 }; @{ Status = 404 }; @{ Status = 429 }; @{ Status = 500 }
    ) {
        param($Status)
        $script:httpStatus = $Status
        Mock Invoke-RestMethod {
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$script:httpStatus)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('sensitive server body', $response)
        }
        { Invoke-SyncHttp -Method GET -Uri 'https://api.github.com/test' -Headers @{ Authorization = 'sensitive' } } |
            Should -Throw "Synchronization HTTP GET request failed (status $Status)."
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $MaximumRedirection -eq 0 }
    }
}

Describe 'Entrypoint diagnostics and exit status (offline)' {
    BeforeEach {
        $script:previousErrorWriter = [Console]::Error
        $script:previousOutputWriter = [Console]::Out
        $script:errorWriter = [IO.StringWriter]::new()
        $script:outputWriter = [IO.StringWriter]::new()
        [Console]::SetError($script:errorWriter)
        [Console]::SetOut($script:outputWriter)
        Mock Invoke-RestMethod { throw 'Network access is forbidden in tests.' }
    }

    AfterEach {
        [Console]::SetError($script:previousErrorWriter)
        [Console]::SetOut($script:previousOutputWriter)
        $script:errorWriter.Dispose()
        $script:outputWriter.Dispose()
    }

    It 'surfaces an intentionally sanitized configuration error with failure exit status' {
        Mock Invoke-AzureBoardsSync {
            throw [SyncFailure]::new('Invalid or incomplete Azure Boards configuration; organization, project, PAT, and both state mappings are required.')
        }
        Invoke-SyncEntryPoint | Should -Be 1
        $script:errorWriter.ToString().Trim() | Should -Be 'Invalid or incomplete Azure Boards configuration; organization, project, PAT, and both state mappings are required.'
        $script:outputWriter.ToString() | Should -Be ''
    }

    It 'surfaces only the sanitized HTTP operation and status' {
        Mock Invoke-RestMethod {
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('sensitive response content', $response)
        }
        Mock Invoke-AzureBoardsSync {
            Invoke-SyncHttp -Method PATCH -Uri 'https://dev.azure.com/org/project/_apis/wit/workitems/1?api-version=7.1' -Headers @{ Authorization = 'sensitive' }
        }
        Invoke-SyncEntryPoint | Should -Be 1
        $script:errorWriter.ToString().Trim() | Should -Be 'Synchronization HTTP PATCH request failed (status 403).'
        $script:outputWriter.ToString() | Should -Be ''
    }

    It 'keeps untyped runtime errors generic: <Case>' -TestCases @(
        @{ Case = 'unexpected'; UnsafeMessage = 'Sensitive runtime input, request headers, and response content' }
        @{ Case = 'HTTP lookalike'; UnsafeMessage = 'Synchronization HTTP GET request failed (status 403).' }
    ) {
        param($UnsafeMessage)
        $script:unsafeFailureMessage = $UnsafeMessage
        Mock Invoke-AzureBoardsSync { throw $script:unsafeFailureMessage }
        Invoke-SyncEntryPoint | Should -Be 1
        $script:errorWriter.ToString().Trim() | Should -Be 'Azure Boards synchronization failed. Check configuration, maintainer labels, mapping integrity, and service availability.'
        $script:outputWriter.ToString() | Should -Be ''
    }

    It 'prints a simple success or skip result and returns a successful exit status' {
        Mock Invoke-AzureBoardsSync { 'Skipped: Azure Boards is not configured.' }
        Invoke-SyncEntryPoint | Should -Be 0
        $script:outputWriter.ToString().Trim() | Should -Be 'Skipped: Azure Boards is not configured.'
        $script:errorWriter.ToString() | Should -Be ''
        Should -Invoke Invoke-RestMethod -Times 0
    }
}
