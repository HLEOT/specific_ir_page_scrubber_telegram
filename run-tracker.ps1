param(
    [string]$ConfigPath = ".\tracker-config.json",
    [switch]$TestTelegram,
    [switch]$Watch,
    [int]$IntervalSeconds = 10,
    [string]$CheckDate = "",
    [switch]$DateRecognitionOnly,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Get-AbsolutePath {
    param([string]$PathValue)

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    return [System.IO.Path]::GetFullPath((Join-Path $basePath $PathValue))
}

function Ensure-Directory {
    param([string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        New-Item -ItemType Directory -Path $PathValue | Out-Null
    }
}

function Read-Config {
    param([string]$PathValue)

    $resolvedPath = Get-AbsolutePath -PathValue $PathValue
    if (-not (Test-Path -LiteralPath $resolvedPath)) {
        throw "Config file not found: $resolvedPath"
    }

    return Get-Content -LiteralPath $resolvedPath -Raw | ConvertFrom-Json
}

function Read-State {
    param([string]$PathValue)

    if (-not (Test-Path -LiteralPath $PathValue)) {
        return @{
            alerted = @()
            checkedAtUtc = $null
        }
    }

    $raw = Get-Content -LiteralPath $PathValue -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @{
            alerted = @()
            checkedAtUtc = $null
        }
    }

    $state = $raw | ConvertFrom-Json
    $alerted = @()
    if ($state.alerted) {
        $alerted = @($state.alerted)
    }

    return @{
        alerted = $alerted
        checkedAtUtc = $state.checkedAtUtc
    }
}

function Write-State {
    param(
        [string]$PathValue,
        [hashtable]$State
    )

    $payload = @{
        alerted = @($State.alerted | Select-Object -Unique)
        checkedAtUtc = $State.checkedAtUtc
    }

    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $PathValue -Encoding UTF8
}

function Write-LogLine {
    param(
        [string]$LogPath,
        [string]$Message
    )

    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $line = "[${timestamp}] $Message"
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Invoke-TrackedRequest {
    param([string]$Url)

    $headers = @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) FDA-GTx104-Tracker/1.0"
    }

    return Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec 30 -UseBasicParsing
}

function Get-GraceTodayDate {
    $easternTz = [System.TimeZoneInfo]::FindSystemTimeZoneById("Eastern Standard Time")
    return [System.TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $easternTz).Date
}

function Resolve-TargetDate {
    if ([string]::IsNullOrWhiteSpace($CheckDate)) {
        return Get-GraceTodayDate
    }

    try {
        return [datetime]::ParseExact($CheckDate, "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture).Date
    }
    catch {
        throw "CheckDate must use yyyy-MM-dd format."
    }
}

function Get-NormalizedText {
    param([string]$Text)

    if ($null -eq $Text) {
        return ""
    }

    $value = $Text -replace "<script[\s\S]*?</script>", " "
    $value = $value -replace "<style[\s\S]*?</style>", " "
    $value = $value -replace "<[^>]+>", " "
    $value = [System.Net.WebUtility]::HtmlDecode($value)
    $value = $value -replace "\s+", " "
    return $value.Trim()
}

function Get-PageLinks {
    param(
        [string]$BaseUrl,
        [object]$Response
    )

    $items = @()

    if ($Response.Links) {
        foreach ($link in $Response.Links) {
            if (-not $link.href) {
                continue
            }

            $href = $link.href.Trim()
            if ([string]::IsNullOrWhiteSpace($href)) {
                continue
            }

            try {
                $absolute = [System.Uri]::new([System.Uri]$BaseUrl, $href).AbsoluteUri
            }
            catch {
                continue
            }

            $text = ""
            if ($link.innerText) {
                $text = Get-NormalizedText -Text $link.innerText
            } elseif ($link.outerHTML) {
                $text = Get-NormalizedText -Text $link.outerHTML
            }

            $items += [PSCustomObject]@{
                title = $text
                url = $absolute
            }
        }
    }

    if ($items.Count -gt 0) {
        return $items
    }

    $html = [string]$Response.Content
    $pattern = '<a[^>]+href=["''](?<href>[^"'']+)["''][^>]*>(?<text>.*?)</a>'
    foreach ($match in [regex]::Matches($html, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        $href = $match.Groups["href"].Value
        $text = Get-NormalizedText -Text $match.Groups["text"].Value

        if ([string]::IsNullOrWhiteSpace($href)) {
            continue
        }

        try {
            $absolute = [System.Uri]::new([System.Uri]$BaseUrl, $href).AbsoluteUri
        }
        catch {
            continue
        }

        $items += [PSCustomObject]@{
            title = $text
            url = $absolute
        }
    }

    return $items
}

function Get-GraceCandidates {
    $pressUrl = "https://www.gracetx.com/en/investors/news-events/press-releases"
    $response = Invoke-TrackedRequest -Url $pressUrl
    $links = Get-PageLinks -BaseUrl $pressUrl -Response $response

    $matches = $links | Where-Object {
        $_.url -match "gracetx\.com/.*/press-releases/detail/" -or
        $_.url -match "gracetx\.com/investors/news-events/press-releases/detail/"
    } | Select-Object -Unique url, title

    return @($matches | Select-Object -First 6)
}

function Get-PressReleaseDate {
    param([string]$BodyText)

    $monthPattern = "((Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?|(January|February|March|April|May|June|July|August|September|October|November|December))"
    $dateMatch = [regex]::Match($BodyText, "\b$monthPattern\s+\d{1,2},\s+\d{4}\b")
    if (-not $dateMatch.Success) {
        return $null
    }

    $dateText = $dateMatch.Value -replace "Sept\.", "Sep."
    foreach ($format in @("MMMM d, yyyy", "MMM d, yyyy", "MMM. d, yyyy")) {
        try {
            return [datetime]::ParseExact($dateText, $format, [System.Globalization.CultureInfo]::InvariantCulture).Date
        }
        catch {
        }
    }

    return $null
}

function Get-DecisionType {
    param(
        [string]$Title,
        [string]$BodyText
    )

    $titleText = Get-NormalizedText -Text $Title
    $body = Get-NormalizedText -Text $BodyText
    $combined = "$titleText $body"

    $trackerTerms = "(GTx-104|Grace Therapeutics|nimodipine)"
    if ($combined -notmatch $trackerTerms) {
        return $null
    }

    $ignorePatterns = @(
        "potential FDA approval",
        "in anticipation of potential FDA approval",
        "seeking approval",
        "submission seeking approval",
        "accepted for review",
        "acceptance for review",
        "target date",
        "PDUFA",
        "if GTx-104 is approved",
        "if approved",
        "look forward to continuing to engage with the FDA"
    )

    $crlPatterns = @(
        "\bcomplete response letter\b",
        "\bCRL\b",
        "\breceived? (an? )?complete response letter\b",
        "\bFDA .* declined to approve\b",
        "\bFDA .*cannot approve\b"
    )

    foreach ($pattern in $crlPatterns) {
        if ($combined -match $pattern) {
            return "CRL"
        }
    }

    $approvalPatterns = @(
        "\bFDA (has )?approved\b",
        "\bapproved by the FDA\b",
        "\bgranted approval\b",
        "\breceive[sd]? FDA approval\b",
        "\bU\.S\. Food and Drug Administration .* approved\b",
        "\bannounces FDA approval\b",
        "\bapproval of GTx-104\b"
    )

    $matchedApproval = $false
    foreach ($pattern in $approvalPatterns) {
        if ($combined -match $pattern) {
            $matchedApproval = $true
            break
        }
    }

    if (-not $matchedApproval) {
        return $null
    }

    foreach ($pattern in $ignorePatterns) {
        if ($combined -match $pattern -and $titleText -notmatch "(approved|approval)") {
            return $null
        }
    }

    if ($titleText -match "(potential|seeking|accepted for review|acceptance for review|PDUFA)") {
        return $null
    }

    return "APPROVAL"
}

function Get-DecisionEvents {
    param(
        [object[]]$Candidates,
        [datetime]$TodayDate
    )

    $events = @()
    foreach ($candidate in $Candidates) {
        try {
            $response = Invoke-TrackedRequest -Url $candidate.url
            $title = if ([string]::IsNullOrWhiteSpace($candidate.title)) {
                Get-NormalizedText -Text $response.ParsedHtml.title
            } else {
                $candidate.title
            }

            $body = Get-NormalizedText -Text $response.Content
            $publishedDate = Get-PressReleaseDate -BodyText $body
            if ($null -eq $publishedDate -or $publishedDate -ne $TodayDate) {
                continue
            }

            $decisionType = Get-DecisionType -Title $title -BodyText $body
            if (-not $decisionType) {
                continue
            }

            $snippetLength = [Math]::Min(320, $body.Length)
            $snippet = if ($snippetLength -gt 0) { $body.Substring(0, $snippetLength) } else { "" }
            $events += [PSCustomObject]@{
                key = "$decisionType|$($candidate.url)"
                decisionType = $decisionType
                title = $title
                url = $candidate.url
                snippet = $snippet
                publishedDate = $publishedDate.ToString("yyyy-MM-dd")
            }
        }
        catch {
            Write-Warning "Failed to inspect $($candidate.url): $($_.Exception.Message)"
        }
    }

    return @($events | Sort-Object key -Unique)
}

function Get-DateRecognitionEvents {
    param(
        [object[]]$Candidates,
        [datetime]$TargetDate
    )

    $events = @()
    foreach ($candidate in $Candidates) {
        try {
            $response = Invoke-TrackedRequest -Url $candidate.url
            $title = if ([string]::IsNullOrWhiteSpace($candidate.title)) {
                Get-NormalizedText -Text $response.ParsedHtml.title
            } else {
                $candidate.title
            }

            $body = Get-NormalizedText -Text $response.Content
            $publishedDate = Get-PressReleaseDate -BodyText $body
            if ($null -eq $publishedDate -or $publishedDate -ne $TargetDate) {
                continue
            }

            $snippetLength = [Math]::Min(320, $body.Length)
            $snippet = if ($snippetLength -gt 0) { $body.Substring(0, $snippetLength) } else { "" }
            $events += [PSCustomObject]@{
                key = "DATE-TEST|$($candidate.url)"
                decisionType = "DATE-TEST"
                title = $title
                url = $candidate.url
                snippet = $snippet
                publishedDate = $publishedDate.ToString("yyyy-MM-dd")
            }
        }
        catch {
            Write-Warning "Failed to inspect $($candidate.url): $($_.Exception.Message)"
        }
    }

    return @($events | Sort-Object key -Unique)
}

function Send-TelegramMessage {
    param(
        [object]$TelegramConfig,
        [object]$Event,
        [switch]$DryRunMode
    )

    if (-not $TelegramConfig.botToken) {
        throw "telegram.botToken is missing from tracker-config.json"
    }

    if (-not $TelegramConfig.chatId) {
        throw "telegram.chatId is missing from tracker-config.json"
    }

    $decisionLabel = switch ($Event.decisionType) {
        "CRL" { "Complete Response Letter" }
        "DATE-TEST" { "Date Recognition Test" }
        default { "FDA Approval" }
    }
    $prefix = if ($TelegramConfig.mentionText) { "$($TelegramConfig.mentionText)`n" } else { "" }
    $text = @(
        "${prefix}GTx-104 tracker: $decisionLabel detected"
        $Event.title
        $Event.url
    ) -join "`n"

    $payload = @{
        chat_id = [string]$TelegramConfig.chatId
        text = $text
        disable_web_page_preview = $false
    }

    if ($DryRunMode) {
        Write-Host ("DRY RUN TELEGRAM: " + ($payload | ConvertTo-Json -Depth 5))
        return
    }

    $uri = "https://api.telegram.org/bot$($TelegramConfig.botToken)/sendMessage"
    Invoke-RestMethod -Method Post -Uri $uri -ContentType "application/json" -Body ($payload | ConvertTo-Json -Depth 5) | Out-Null
}

$config = Read-Config -PathValue $ConfigPath
$resolvedConfigPath = Get-AbsolutePath -PathValue $ConfigPath
$workspaceRoot = Split-Path -Parent $resolvedConfigPath
$stateDir = Join-Path $workspaceRoot ".state"
Ensure-Directory -PathValue $stateDir

$statePath = Join-Path $stateDir "tracker-state.json"
$logPath = Join-Path $stateDir "tracker.log"

if ($TestTelegram) {
    $testEvent = [PSCustomObject]@{
        title = "Test ping from the GTx-104 FDA tracker"
        url = "https://www.gracetx.com/en/investors/news-events/press-releases"
        snippet = "This is a test notification so you can confirm the Telegram bot token and chat ID are correct."
        decisionType = "APPROVAL"
    }

    Send-TelegramMessage -TelegramConfig $config.telegram -Event $testEvent -DryRunMode:$DryRun
    Write-LogLine -LogPath $logPath -Message "Sent Telegram test notification."
    exit 0
}

function Invoke-TrackerRun {
    $state = Read-State -PathValue $statePath
    $todayDate = Resolve-TargetDate

    Write-LogLine -LogPath $logPath -Message ("Starting GTx-104 Grace press release check for {0}." -f $todayDate.ToString("yyyy-MM-dd"))

    $candidates = @(Get-GraceCandidates | Select-Object -Unique url, title)
    Write-LogLine -LogPath $logPath -Message ("Collected {0} recent Grace press release links." -f $candidates.Count)

    if ($DateRecognitionOnly) {
        $events = @(Get-DateRecognitionEvents -Candidates $candidates -TargetDate $todayDate)
        Write-LogLine -LogPath $logPath -Message ("Detected {0} press release(s) matching the target date." -f $events.Count)
    } else {
        $events = @(Get-DecisionEvents -Candidates $candidates -TodayDate $todayDate)
        Write-LogLine -LogPath $logPath -Message ("Detected {0} qualifying decision-like press releases dated today." -f $events.Count)
    }

    $newEvents = @()
    foreach ($event in $events) {
        if ($state.alerted -contains $event.key) {
            continue
        }

        $newEvents += $event
    }

    foreach ($event in $newEvents) {
        Write-LogLine -LogPath $logPath -Message ("New event: {0} | {1}" -f $event.decisionType, $event.title)
        Send-TelegramMessage -TelegramConfig $config.telegram -Event $event -DryRunMode:$DryRun
        if (-not $DryRun) {
            $state.alerted += $event.key
        }
    }

    $state.checkedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-State -PathValue $statePath -State $state

    if ($newEvents.Count -eq 0) {
        if ($events.Count -gt 0) {
            Write-LogLine -LogPath $logPath -Message "Matching press release found, but it was already alerted previously."
        } elseif ($DateRecognitionOnly) {
            Write-LogLine -LogPath $logPath -Message "No press release matched the requested date."
        } else {
            Write-LogLine -LogPath $logPath -Message "No new approval/CRL press release published today."
        }
    }
}

if ($Watch) {
    if ($IntervalSeconds -lt 5) {
        throw "IntervalSeconds must be at least 5."
    }

    Write-LogLine -LogPath $logPath -Message ("Watch mode enabled. Polling every {0} second(s)." -f $IntervalSeconds)
    while ($true) {
        try {
            Invoke-TrackerRun
        }
        catch {
            Write-LogLine -LogPath $logPath -Message ("Run failed: {0}" -f $_.Exception.Message)
        }

        Start-Sleep -Seconds $IntervalSeconds
    }
}

Invoke-TrackerRun
