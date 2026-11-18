#requires -Version 5.1

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ==========================================================
# HELPER FUNCTIONS
# ==========================================================

function Add-ReportSection {
    param([System.Collections.Generic.List[string]]$Report, [string]$Title)
    $Report.Add("")
    $Report.Add($Title)
    $Report.Add(("-" * 84))
}

function Get-NormalizedAppKey {
    param(
        [string]$ServiceName,
        [string]$RuntimeRoot
    )
    $raw = if ($RuntimeRoot) { Split-Path $RuntimeRoot -Leaf } else { $ServiceName }
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $ServiceName }

    $key = $raw.ToUpperInvariant()
    # Strip prefixes and trailing digits
    $key = $key -replace '^(JDACONNECT[-_]|JDA[-_]|MULE_EE_|MULE[-_])', ''
    $key = $key -replace '\d+$', ''
    $key = $key.Replace('-', '').Replace('_', '').Replace(' ', '')

    if ($key -eq 'USEP') { $key = 'GGEP' }
    return $key
}

function Parse-WrapperConf {
    param([string[]]$Content)
    
    $result = @{
        InitMemory            = "Missing"
        MaxMemory             = "Missing"
        MetaspaceSize         = "Missing"
        MaxMetaspaceSize      = "Missing"
        JmxRemote             = "Missing"
        JmxPort               = "Missing"
        JmxAuth               = "Missing"
        JmxSsl                = "Missing"
        RmiPort               = "Missing"
        OracleJdbcCompliance  = "Not Configured"
        AnypointGatekeeper    = "Not Configured"
        AnypointBaseUri       = "Not Configured"
        JavaTmpDir            = "Not Configured"
        MuleDeployApplications = "Missing"
    }
    
    if (-not $Content) { return $result }

    foreach ($line in $Content) {
        if ($null -eq $line) { continue }
        $line = $line.Trim()
        if ($line.StartsWith("#") -or [string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match "^wrapper\.java\.initmemory\s*=\s*(.+)$") { $result.InitMemory = $matches[1].Trim() }
        if ($line -match "^wrapper\.java\.maxmemory\s*=\s*(.+)$")  { $result.MaxMemory = $matches[1].Trim() }
        if ($line -match "-XX:MetaspaceSize\s*=\s*(.+)$")          { $result.MetaspaceSize = $matches[1].Trim() }
        if ($line -match "-XX:MaxMetaspaceSize\s*=\s*(.+)$")       { $result.MaxMetaspaceSize = $matches[1].Trim() }
        
        if ($line -match "-Dcom\.sun\.management\.jmxremote$")                          { $result.JmxRemote = "Enabled" }
        if ($line -match "-Dcom\.sun\.management\.jmxremote\s*=\s*(.+)$")               { $result.JmxRemote = $matches[1].Trim() }
        if ($line -match "-Dcom\.sun\.management\.jmxremote\.port\s*=\s*(.+)$")         { $result.JmxPort = $matches[1].Trim() }
        if ($line -match "-Dcom\.sun\.management\.jmxremote\.authenticate\s*=\s*(.+)$") { $result.JmxAuth = $matches[1].Trim() }
        if ($line -match "-Dcom\.sun\.management\.jmxremote\.ssl\s*=\s*(.+)$")          { $result.JmxSsl = $matches[1].Trim() }
        if ($line -match "-Dcom\.sun\.management\.jmxremote\.rmi\.port\s*=\s*(.+)$")    { $result.RmiPort = $matches[1].Trim() }

        if ($line -match '-Doracle\.jdbc\.J2EE13Compliant=(.+)$') { $result.OracleJdbcCompliance = $matches[1].Trim() }
        if ($line -match '-Danypoint\.platform\.gatekeeper=(.+)$') { $result.AnypointGatekeeper = $matches[1].Trim() }
        
        # Clean AnypointBaseUri HTML tags and trailing slashes
        if ($line -match '-Danypoint\.platform\.base_uri=(.+)$') {
            $uri = $matches[1].Trim()
            $uri = ($uri -replace '<[^>]+>', '').Trim().TrimEnd('/')
            $result.AnypointBaseUri = $uri
        }

        if ($line -match '-Djava\.io\.tmpdir=(.+)$') { $result.JavaTmpDir = $matches[1].Trim() }
        if ($line -match '-Dmule\.deploy\.applications=(.+)$') {
            $result.MuleDeployApplications = $matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $result
}

function Add-WrapperTable {
    param($Report, $Title, [string[]]$PrivContent, [string[]]$PubContent)
    
    $Report.Add("")
    $Report.Add($Title)
    $Report.Add(("-" * 84))
    
    $pHas = ($PrivContent -and $PrivContent.Count -gt 0)
    $nHas = ($PubContent -and $PubContent.Count -gt 0)

    if (-not $pHas -and -not $nHas) {
        $Report.Add("[PASS] wrapper.conf not present on Reference - Not Required on Public.")
        return $true
    }
    if ($pHas -and -not $nHas) {
        $Report.Add("[FAIL] wrapper.conf present on Reference server but missing on Public.")
        return $false
    }
    if (-not $pHas -and $nHas) {
        $Report.Add("[INFO] wrapper.conf found only on Public server.")
        return $true
    }

    $Report.Add(("{0,-24} {1,-20} {2,-20} {3}" -f "Property", "Reference", "Public", "Status"))
    $Report.Add(("-" * 84))

    $PrivParsed = Parse-WrapperConf -Content $PrivContent
    $PubParsed  = Parse-WrapperConf -Content $PubContent
    
    $keys = @(
        "InitMemory", "MaxMemory", "MetaspaceSize", "MaxMetaspaceSize",
        "JmxRemote", "JmxPort", "JmxAuth", "JmxSsl", "RmiPort",
        "OracleJdbcCompliance", "AnypointGatekeeper", "AnypointBaseUri"
    )
    $allPassed = $true

    foreach ($key in $keys) {
        $v1 = $PrivParsed[$key]
        $v2 = $PubParsed[$key]

        # Normalized URL handling (strip HTML & default SSL port :443)
        $dispV1 = $v1
        $dispV2 = $v2
        if ($key -eq "AnypointBaseUri") {
            $v1Norm = ($v1 -replace '<[^>]+>', '').Trim().TrimEnd('/') -replace ':443$', ''
            $v2Norm = ($v2 -replace '<[^>]+>', '').Trim().TrimEnd('/') -replace ':443$', ''
            if ($v1Norm -eq $v2Norm -and $v1Norm -notin @("Missing", "Not Configured")) {
                $status = "[PASS]"
                $dispV1 = "Configured"
                $dispV2 = "Configured"
            } elseif ($v1Norm -in @("Missing", "Not Configured") -and $v2Norm -in @("Missing", "Not Configured")) {
                $status = "[PASS]"
                $dispV1 = "Not Configured"
                $dispV2 = "Not Configured"
            } else {
                $status = "[FAIL]"
                $allPassed = $false
            }
        } else {
            if ($v1 -eq $v2) {
                $status = "[PASS]"
            } else {
                $status = "[FAIL]"
                $allPassed = $false
            }
        }
        $Report.Add(("{0,-24} {1,-20} {2,-20} {3}" -f $key, $dispV1, $dispV2, $status))
    }

    if ($Title -match "GGSVC") {
        $svcPresent = $PubParsed.MuleDeployApplications -eq "connect-config-service"
        $svcStatus  = if ($svcPresent) { "[PASS]" } else { "[FAIL]" }

        $Report.Add(
            ("{0,-24} {1,-20} {2}" -f
            "MuleDeployApplications",
            $(if ($svcPresent) { "Present" } else { "Missing" }),
            $svcStatus)
        )

        if (-not $svcPresent) {
            $allPassed = $false
        }
    }

    # JavaTmpDir presence check
    $pTmp = ($PrivParsed.JavaTmpDir -notin @("Missing", "Not Configured") -and -not [string]::IsNullOrWhiteSpace($PrivParsed.JavaTmpDir))
    $nTmp = ($PubParsed.JavaTmpDir -notin @("Missing", "Not Configured") -and -not [string]::IsNullOrWhiteSpace($PubParsed.JavaTmpDir))
    if ($pTmp -and $nTmp) {
        $Report.Add(("{0,-24} {1,-20} {2,-20} {3}" -f "JavaTmpDir (Presence)", "Configured", "Configured", "[PASS]"))
    } elseif (-not $pTmp -and -not $nTmp) {
        $Report.Add(("{0,-24} {1,-20} {2,-20} {3}" -f "JavaTmpDir (Presence)", "Not Set", "Not Set", "[PASS]"))
    } elseif ($pTmp -and -not $nTmp) {
        $Report.Add(("{0,-24} {1,-20} {2,-20} {3}" -f "JavaTmpDir (Presence)", "Configured", "Missing", "[FAIL]"))
        $allPassed = $false
    } else {
        $Report.Add(("{0,-24} {1,-20} {2,-20} {3}" -f "JavaTmpDir (Presence)", "Not Set", "Configured", "[INFO]"))
    }

    return $allPassed
}

# ==========================================================
# UNIFIED REMOTE COLLECTOR SCRIPTBLOCK
# ==========================================================

$CollectorScriptBlock = {
    param([string]$Role)

    function Find-Folder {
        param([string]$FolderName, [string]$PreferredDrive)
        $drives = @()
        if ($PreferredDrive) { $drives += $PreferredDrive.TrimEnd('\') + "\" }
        $drives += @("F:\", "D:\", "E:\", "C:\")
        $uniqueDrives = $drives | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

        foreach ($d in $uniqueDrives) {
            $p = Join-Path $d $FolderName
            if (Test-Path $p) { return $p }

            $match = Get-ChildItem -Path $d -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -ieq $FolderName -or $_.Name -like "*$FolderName*" } |
                     Select-Object -First 1
            if ($match) { return $match.FullName }
        }
        return $null
    }

    $runningSvcs = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
                     Where-Object { $_.State -eq 'Running' -and $_.Name -like 'mule_ee_*' })

    $applications = @()
    $logResults   = @()
    $criticalMap  = @{}
    $CriticalPatterns = @(
        "OutOfMemoryError", "BindException", "AccessDeniedException",
        "UnknownHostException", "ConnectException", "SSLException",
        "ORA-", "Permission denied", "FileNotFoundException"
    )
    foreach ($pat in $CriticalPatterns) {
        $criticalMap[$pat] = @{ Count = 0; Sample = ""; LogFile = "" }
    }

    foreach ($svc in $runningSvcs) {
        if ($svc.PathName -match '^"([^"]+)"') {
            $exePath = $matches[1]
        } else {
            $exePath = ($svc.PathName -split '\s+')[0]
        }

        $runtimeRoot = $null
        $currentPath = if ($exePath) { Split-Path $exePath -Parent } else { $null }
        while ($currentPath) {
            if ((Split-Path $currentPath -Leaf) -ieq "Mule") {
                $runtimeRoot = Split-Path $currentPath -Parent
                break
            }
            $parent = Split-Path $currentPath -Parent
            if ($parent -eq $currentPath) { break }
            $currentPath = $parent
        }

        $wrapFile = $null
        if (-not [string]::IsNullOrWhiteSpace($runtimeRoot) -and (Test-Path $runtimeRoot)) {
            $wrapperCandidates = @(
                (Join-Path $runtimeRoot "Mule\conf\wrapper.conf"),
                (Join-Path $runtimeRoot "conf\wrapper.conf")
            )
            $wrapFile = $wrapperCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
            if (-not $wrapFile) {
                $found = Get-ChildItem -Path $runtimeRoot -Filter "wrapper.conf" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { $wrapFile = $found.FullName }
            }
        }
        $wrapExists  = [bool]$wrapFile
        $wrapContent = if ($wrapFile -and (Test-Path $wrapFile)) { @(Get-Content $wrapFile -ErrorAction SilentlyContinue) } else { @() }

        # Log & Critical Pattern Scanning (Public Server Only - Strictly active *.log files, ignoring rollovers *.log.1)
        $logsExist = $false
        $logFilesCount = 0
        if ($Role -eq 'Public') {
            $logDir = if (-not [string]::IsNullOrWhiteSpace($runtimeRoot) -and (Test-Path $runtimeRoot)) { Join-Path $runtimeRoot "Mule\logs" } else { $null }
            $logDirExists = [bool]($logDir -and (Test-Path $logDir))
            $logFiles = if ($logDirExists) { @(Get-ChildItem $logDir -File -ErrorAction SilentlyContinue) } else { @() }
            $logFilesCount = $logFiles.Count
            $logsExist = ($logFilesCount -gt 0)
            $appFolder = if ($runtimeRoot) { Split-Path $runtimeRoot -Leaf } else { "Unknown" }

            if ($logsExist) {
                # Scan only current active *.log files (excludes old rollovers like .log.1, .log.2)
                $targetLogs = $logFiles |
                    Where-Object {
                        $_.Name -match '\.log$' -and
                        $_.Name -notmatch '(?i)gc' -and
                        $_.Name -notmatch '(?i)jvm-gc' -and
                        $_.Name -notmatch '(?i)^mule_agent' -and
                        $_.Name -notmatch '(?i)^mule-domain-default' -and
                        $_.Name -notmatch '(?i)^wrapper' -and
                        $_.Name -notmatch '(?i)^startup'
                    } |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 2

                foreach ($log in $targetLogs) {
                    $content    = Get-Content $log.FullName -Tail 500 -ErrorAction SilentlyContinue
                    $errCount   = @($content | Select-String '\bERROR\b').Count
                    $fatalCount = @($content | Select-String '\bFATAL\b').Count
                    $exCount    = @($content | Select-String '\bException\b').Count

                    $logResults += [PSCustomObject]@{
                        ServiceName = $svc.Name
                        AppFolder   = $appFolder
                        LogName     = $log.Name
                        Errors      = $errCount
                        Fatals      = $fatalCount
                        Exceptions  = $exCount
                    }

                    $actionableLines = @($content | Where-Object { $_ -match "\bERROR\b" -or $_ -match "\bFATAL\b" -or $_ -match "Caused by:" })
                    foreach ($pat in $CriticalPatterns) {
                        $matches = @($actionableLines | Select-String -Pattern $pat -SimpleMatch)
                        $hits = $matches.Count
                        if ($hits -gt 0) {
                            $criticalMap[$pat].Count += $hits
                            if ([string]::IsNullOrWhiteSpace($criticalMap[$pat].Sample)) {
                                $sampleLine = $matches[0].Line.Trim()
                                if ($sampleLine.Length -gt 130) { $sampleLine = $sampleLine.Substring(0, 127) + "..." }
                                $criticalMap[$pat].Sample  = $sampleLine
                                $criticalMap[$pat].LogFile = $log.Name
                            }
                        }
                    }
                }
            }
        }

        $applications += [PSCustomObject]@{
            ServiceName      = $svc.Name
            State            = $svc.State
            StartMode        = $svc.StartMode
            DelayedAutoStart = $svc.DelayedAutoStart
            StartName        = $svc.StartName
            PathName         = $svc.PathName
            RuntimeRoot      = $runtimeRoot
            WrapperExists    = $wrapExists
            WrapperLines     = $wrapContent
            LogsExist        = $logsExist
            LogFileCount     = $logFilesCount
            TempExists       = $false
            TempPath         = $null
        }
    }

    $prefDrive = $null
    foreach ($app in $applications) {
        if (-not [string]::IsNullOrWhiteSpace($app.RuntimeRoot)) {
            $prefDrive = Split-Path $app.RuntimeRoot -Qualifier
            if ($prefDrive) { break }
        }
    }

    $folderPaths = @{}
    foreach ($f in @("Java8", "JConn_CPS", "Jconn_Automation", "JDA", "_SW")) {
        $folderPaths[$f] = Find-Folder -FolderName $f -PreferredDrive $prefDrive
    }

    $cpsPath  = $folderPaths["JConn_CPS"]
    $cpsCount = if ($cpsPath -and (Test-Path $cpsPath)) { @(Get-ChildItem $cpsPath -Directory -ErrorAction SilentlyContinue).Count } else { 0 }

    $tempRootPath   = Find-Folder -FolderName "Temp" -PreferredDrive $prefDrive
    $tempRootExists = [bool]($tempRootPath -and (Test-Path $tempRootPath))

    $tempSubDirs = if ($tempRootExists) {
        @(Get-ChildItem -Path $tempRootPath -Directory -ErrorAction SilentlyContinue)
    } else { @() }

    foreach ($app in $applications) {
        $normApp = ($app.ServiceName -replace '^mule_ee_', '').Replace('-','').Replace('_','').Replace(' ','').ToUpperInvariant()
        $normApp = $normApp -replace '\d+$', ''

        $foundTemp = $null
        foreach ($td in $tempSubDirs) {
            $normTd = ($td.Name -replace '^mule_ee_', '').Replace('-','').Replace('_','').Replace(' ','').ToUpperInvariant()
            $normTd = $normTd -replace '\d+$', ''
            if ($normTd -eq $normApp) {
                $foundTemp = $td.FullName
                break
            }
        }
        $app.TempPath   = if ($foundTemp) { $foundTemp } else { if ($tempRootPath) { Join-Path $tempRootPath $app.ServiceName } else { $null } }
        $app.TempExists = [bool]$foundTemp
    }

    $scanDrives = @($prefDrive, "F:\", "D:\", "E:\", "C:\") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
    $amqFolders = @()
    foreach ($sd in $scanDrives) {
        $amqFolders += @(Get-ChildItem $sd -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "AMQ|ActiveMQ" } | Select-Object -ExpandProperty FullName)
    }

    # ActiveMQ Listener Detection
    $AmqListeningPorts = @()
    foreach($Port in @(11080,31080,51080)){
        $listener = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue
        if($listener){
            $AmqListeningPorts += $Port
        }
    }

    # Public-specific environment metrics
    $pubMetrics = @{}
    if ($Role -eq 'Public') {
        $javaVer = try { (java -version 2>&1 | Select-Object -First 1).ToString() } catch { "Not Found" }
        $javaExe = (Get-Command java -ErrorAction SilentlyContinue).Source
        $cpu = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average).Average
        $os  = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $totalMem = if ($os) { $os.TotalVisibleMemorySize / 1MB } else { 0 }
        $freeMem  = if ($os) { [math]::Round(($os.FreePhysicalMemory / 1MB), 2) } else { 0 }
        $memUsage = if ($totalMem -gt 0) { [math]::Round((($totalMem - $freeMem) / $totalMem) * 100, 0) } else { 0 }

        $targetDriveLetter = if ($prefDrive) { ($prefDrive -replace '[:\\]','').Trim() } else { "F" }
        $disk = Get-PSDrive -Name $targetDriveLetter -ErrorAction SilentlyContinue
        if (-not $disk) { $disk = Get-PSDrive -Name "F" -ErrorAction SilentlyContinue }
        if (-not $disk) { $disk = Get-PSDrive -Name "D" -ErrorAction SilentlyContinue }
        if (-not $disk) { $disk = Get-PSDrive -Name "C" -ErrorAction SilentlyContinue }
        $diskFree = if ($disk) { [math]::Round(($disk.Free / 1GB), 2) } else { 0 }

        $criticalList = @()
        foreach ($pat in $CriticalPatterns) {
            $criticalList += [PSCustomObject]@{
                Pattern = $pat
                Count   = $criticalMap[$pat].Count
                Sample  = $criticalMap[$pat].Sample
                LogFile = $criticalMap[$pat].LogFile
            }
        }

        $pubMetrics = @{
            JavaVer      = $javaVer
            JavaHome     = $env:JAVA_HOME
            JavaExe      = $javaExe
            CPU          = [math]::Round($cpu, 0)
            MemUsage     = $memUsage
            FreeMem      = $freeMem
            DiskFree     = $diskFree
            DriveName    = if ($disk) { $disk.Name } else { "N/A" }
            LogResults   = $logResults
            CriticalList = $criticalList
        }
    }

    [PSCustomObject]@{
        Role              = $Role
        Applications      = $applications
        FolderPaths       = $folderPaths
        CPSCount          = $cpsCount
        TempRoot          = $tempRootExists
        TempRootPath      = $tempRootPath
        AmqFolders        = $amqFolders
        AmqListeningPorts = $AmqListeningPorts
        PrefDrive         = $prefDrive
        Metrics           = $pubMetrics
    }
}

# ==========================================================
# COMPACT WINFORMS UI SETUP
# ==========================================================

$form = New-Object System.Windows.Forms.Form -Property @{
    Text            = "P2P Migration Validator v8.0 (Enterprise Production Cutover)"
    Size            = New-Object System.Drawing.Size(920, 680)
    StartPosition   = "CenterScreen"
    BackColor       = [System.Drawing.Color]::FromArgb(24, 24, 27)
    ForeColor       = [System.Drawing.Color]::White
    Font            = New-Object System.Drawing.Font("Segoe UI", 9)
    FormBorderStyle = "FixedSingle"
    MaximizeBox     = $false
}

$lblHeader = New-Object System.Windows.Forms.Label -Property @{
    Text      = "P2P MIGRATION VALIDATOR v8.0"
    Location  = New-Object System.Drawing.Point(16, 12)
    AutoSize  = $true
    Font      = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    ForeColor = [System.Drawing.Color]::DeepSkyBlue
}

$grpInput = New-Object System.Windows.Forms.GroupBox -Property @{
    Text      = "Migration Scope"
    ForeColor = [System.Drawing.Color]::Gainsboro
    Location  = New-Object System.Drawing.Point(16, 45)
    Size      = New-Object System.Drawing.Size(872, 62)
}

function New-CompactInput ($LabelText, $LblX, $TxtX, $Width) {
    $lbl = New-Object System.Windows.Forms.Label -Property @{
        Text     = $LabelText
        Location = New-Object System.Drawing.Point($LblX, 26)
        AutoSize = $true
    }
    $txt = New-Object System.Windows.Forms.TextBox -Property @{
        Location    = New-Object System.Drawing.Point($TxtX, 23)
        Size        = New-Object System.Drawing.Size($Width, 23)
        BackColor   = [System.Drawing.Color]::FromArgb(45, 45, 48)
        ForeColor   = [System.Drawing.Color]::White
        BorderStyle = "FixedSingle"
    }
    $grpInput.Controls.Add($lbl)
    $grpInput.Controls.Add($txt)
    return $txt
}

$txtCustomer = New-CompactInput "Customer:" 12 76 110
$txtINC      = New-CompactInput "INC (Opt):" 196 260 100
$txtOld      = New-CompactInput "Reference:" 370 435 170
$txtNew      = New-CompactInput "Public:" 618 668 175

$grpOutput = New-Object System.Windows.Forms.GroupBox -Property @{
    Text      = "Validation & Cutover Report"
    ForeColor = [System.Drawing.Color]::Gainsboro
    Location  = New-Object System.Drawing.Point(16, 115)
    Size      = New-Object System.Drawing.Size(872, 450)
}

$output = New-Object System.Windows.Forms.RichTextBox -Property @{
    Location    = New-Object System.Drawing.Point(10, 22)
    Size        = New-Object System.Drawing.Size(852, 416)
    BackColor   = [System.Drawing.Color]::FromArgb(12, 12, 12)
    ForeColor   = [System.Drawing.Color]::Lime
    Font        = New-Object System.Drawing.Font("Consolas", 9.5)
    ReadOnly    = $true
    WordWrap    = $false
    BorderStyle = "None"
    ScrollBars  = "Both"
}
$grpOutput.Controls.Add($output)

function New-ActionBtn ($Text, $X, $Width, $Color) {
    $btn = New-Object System.Windows.Forms.Button -Property @{
        Text      = $Text
        Location  = New-Object System.Drawing.Point($X, 575)
        Size      = New-Object System.Drawing.Size($Width, 34)
        BackColor = $Color
        ForeColor = [System.Drawing.Color]::White
        FlatStyle = "Flat"
        Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        Cursor    = [System.Windows.Forms.Cursors]::Hand
    }
    $btn.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btn)
    return $btn
}

$btnRun        = New-ActionBtn "Run Validation" 16 145 ([System.Drawing.Color]::FromArgb(22, 163, 74))
$btnExportHtml = New-ActionBtn "Export HTML" 170 135 ([System.Drawing.Color]::FromArgb(37, 99, 235))
$btnExportTxt  = New-ActionBtn "Export TXT" 314 125 ([System.Drawing.Color]::FromArgb(30, 64, 175))
$btnCopyInc    = New-ActionBtn "Copy INC Summary" 448 145 ([System.Drawing.Color]::FromArgb(79, 70, 229))
$btnClear      = New-ActionBtn "Clear" 602 100 ([System.Drawing.Color]::FromArgb(71, 85, 105))

$statusBar = New-Object System.Windows.Forms.StatusStrip -Property @{
    BackColor  = [System.Drawing.Color]::FromArgb(38, 38, 42)
    SizingGrip = $false
}
$statusPill = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{
    Text      = "[ READY ]"
    ForeColor = [System.Drawing.Color]::LightGray
    Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
}
$statusText = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{
    Text      = "Enter server names and click Run Validation"
    ForeColor = [System.Drawing.Color]::Gainsboro
    Spring    = $true
    TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
}
$progressBar = New-Object System.Windows.Forms.ToolStripProgressBar -Property @{
    Size                  = New-Object System.Drawing.Size(130, 16)
    Style                 = [System.Windows.Forms.ProgressBarStyle]::Continuous
    Value                 = 0
    Visible               = $false
    MarqueeAnimationSpeed = 30
}
[void]$statusBar.Items.Add($statusPill)
[void]$statusBar.Items.Add($statusText)
[void]$statusBar.Items.Add($progressBar)

$form.Controls.AddRange(@($lblHeader, $grpInput, $grpOutput, $statusBar))

# ==========================================================
# BUTTON EVENTS
# ==========================================================

$btnClear.Add_Click({
    $output.Clear()
    $txtCustomer.Clear()
    $txtINC.Clear()
    $txtOld.Clear()
    $txtNew.Clear()
    $progressBar.Value = 0
    $progressBar.Visible = $false
    $statusPill.Text = "[ READY ]"
    $statusPill.ForeColor = [System.Drawing.Color]::LightGray
    $statusText.Text = "Enter server names and click Run Validation"
})

$btnCopyInc.Add_Click({
    if ($null -eq $script:LastReportData) {
        [System.Windows.Forms.MessageBox]::Show("Run validation first before copying summary.", "No Data") | Out-Null
        return
    }
    $d = $script:LastReportData
    $custIncLine = if ([string]::IsNullOrWhiteSpace($d.INC)) { $d.Customer } else { "$($d.Customer) (INC: $($d.INC))" }
    $summary = @"
==================================================
P2P MIGRATION CUTOVER SUMMARY
==================================================
Customer    : $custIncLine
Reference   : $($d.ReferenceServer)
Public      : $($d.PublicServer)
MRTs Matched: $($d.MatchedPairs.Count) / $($d.PrivData.Applications.Count)
Risk Level  : $($d.RiskLevel)
Decision    : $($d.Recommendation)
Failures    : $($d.FailCount)
Criticals   : $($d.TotalCritical)
Generated   : $($d.Timestamp)
==================================================
"@
    [System.Windows.Forms.Clipboard]::SetText($summary)
    $statusText.Text = "Executive INC summary copied to clipboard!"
})

$btnExportTxt.Add_Click({
    if ([string]::IsNullOrWhiteSpace($output.Text)) {
        [System.Windows.Forms.MessageBox]::Show("There is no report to export.", "Nothing to Export") | Out-Null
        return
    }
    try {
        $cust = if ($txtCustomer.Text.Trim()) { ($txtCustomer.Text.Trim() -replace '[^\w\-]', '_') } else { "Cust" }
        $inc  = if ($txtINC.Text.Trim())      { ($txtINC.Text.Trim() -replace '[^\w\-]', '') }       else { "INC" }
        $file = Join-Path $env:USERPROFILE ("Desktop\P2PValidation_v80_${cust}_${inc}_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".txt")
        $output.Text | Set-Content -Path $file -Encoding UTF8 -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show("Text Report Saved:`n$file", "Export Complete") | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Export Failed:`n$($_.Exception.Message)", "Error") | Out-Null
    }
})

# ==========================================================
# RUN VALIDATION ENGINE
# ==========================================================

$script:LastReportData = $null

$btnRun.Add_Click({
    $output.Clear()
    $OldServer = $txtOld.Text.Trim()
    $NewServer = $txtNew.Text.Trim()

    if (!$OldServer -or !$NewServer) {
        [System.Windows.Forms.MessageBox]::Show("Enter both Reference (Private) and Public server names.", "Missing Details") | Out-Null
        return
    }

    $btnRun.Enabled = $false
    $statusPill.Text = "[ VALIDATING ]"
    $statusPill.ForeColor = [System.Drawing.Color]::DeepSkyBlue
    $statusText.Text = "Executing unified data collection across Reference and Public..."
    $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progressBar.MarqueeAnimationSpeed = 30
    $progressBar.Visible = $true
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Refresh()

    $ValidationStart = Get-Date
    $Report = New-Object 'System.Collections.Generic.List[string]'

    try {
        # BATCH 1: REFERENCE SERVER
        $PrivData = Invoke-Command -ComputerName $OldServer -ErrorAction Stop -ScriptBlock $CollectorScriptBlock -ArgumentList "Reference"
        if ($null -eq $PrivData) { throw "Reference server collection returned no data." }

        # BATCH 2: PUBLIC SERVER
        $PubData = Invoke-Command -ComputerName $NewServer -ErrorAction Stop -ScriptBlock $CollectorScriptBlock -ArgumentList "Public"
        if ($null -eq $PubData) { throw "Public server collection returned no data." }

        $m = $PubData.Metrics

        # DYNAMIC PAIRING
        $PairedApps = @()
        $MatchedPubSvcs = @()

        foreach ($pApp in $PrivData.Applications) {
            $pKey = Get-NormalizedAppKey -ServiceName $pApp.ServiceName -RuntimeRoot $pApp.RuntimeRoot
            $pubMatch = $PubData.Applications | Where-Object { 
                (Get-NormalizedAppKey -ServiceName $_.ServiceName -RuntimeRoot $_.RuntimeRoot) -eq $pKey 
            } | Select-Object -First 1

            if ($pubMatch) { $MatchedPubSvcs += $pubMatch.ServiceName }
            $PairedApps += [PSCustomObject]@{ Key = $pKey; PrivateApp = $pApp; PublicApp = $pubMatch }
        }

        foreach ($pubApp in $PubData.Applications) {
            if ($pubApp.ServiceName -notin $MatchedPubSvcs) {
                $nKey = Get-NormalizedAppKey -ServiceName $pubApp.ServiceName -RuntimeRoot $pubApp.RuntimeRoot
                $PairedApps += [PSCustomObject]@{ Key = $nKey; PrivateApp = $null; PublicApp = $pubApp }
            }
        }

        $matchedPairs   = @($PairedApps | Where-Object { $null -ne $_.PrivateApp -and $null -ne $_.PublicApp })
        $unmatchedCount = $PairedApps.Count - $matchedPairs.Count

        $RiskItems                = @()
        $InfoItems                = @()
        $OnlyOnReference          = @()
        $OnlyOnPublic             = @()
        $ReferenceRequiredMissing = @()

        # AMQ Plain URL Strings generated in main engine (No HTML, no anchor tags)
        $AmqUrls = @(
            "http://${NewServer}:11080/index.html",
            "http://${NewServer}:31080/index.html",
            "http://${NewServer}:51080/index.html"
        )

        # ==========================================================
        # REPORT BUILDING
        # ==========================================================
        $Report.Add("====================================================================================")
        $Report.Add("P2P MIGRATION VALIDATION REPORT v8.0                     [MODE: STRICTLY READ-ONLY]")
        $Report.Add("====================================================================================")
        $incDisplay = if ($txtINC.Text.Trim()) { $txtINC.Text.Trim() } else { "N/A" }
        $Report.Add(("Customer : {0,-24} INC     : {1}" -f $txtCustomer.Text, $incDisplay))
        $Report.Add(("Reference: {0,-24} Public  : {1}" -f $OldServer, $NewServer))
        $Report.Add(("Date     : {0,-24} Changes : 0 Files / 0 Services Modified" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))

        # 1. MRT DISCOVERY & RUNTIME MAPPING
        Add-ReportSection -Report $Report -Title "1. MRT DISCOVERY & RUNTIME MAPPING"
        $privRunningCount = $PrivData.Applications.Count
        $pubRunningCount  = $PubData.Applications.Count
        $discoveryStat    = if ($privRunningCount -gt 0 -and $pubRunningCount -gt 0 -and $unmatchedCount -eq 0) { "[PASS]" } elseif ($matchedPairs.Count -gt 0) { "[WARNING]" } else { "[FAIL]" }

        $Report.Add(("Reference Running MRTs: {0,-5} | Public Running MRTs: {1,-5} | Matched: {2}  {3}" -f $privRunningCount, $pubRunningCount, $matchedPairs.Count, $discoveryStat))
        $Report.Add(("-" * 84))

        $mappingSectionOk = ($matchedPairs.Count -gt 0)
        if ($PairedApps.Count -gt 0) {
            foreach ($pair in $PairedApps) {
                $privSvc  = if ($pair.PrivateApp) { $pair.PrivateApp.ServiceName } else { "None (Reference Missing)" }
                $privRoot = if ($pair.PrivateApp) { $pair.PrivateApp.RuntimeRoot } else { "N/A" }
                $pubSvc   = if ($pair.PublicApp)  { $pair.PublicApp.ServiceName }  else { "None (Public Missing)" }
                $pubRoot  = if ($pair.PublicApp)  { $pair.PublicApp.RuntimeRoot }  else { "N/A" }

                $isMatched = ($null -ne $pair.PrivateApp -and $null -ne $pair.PublicApp)
                $stat = if ($isMatched) { "[PASS]" } else { "[WARNING]" }
                if (-not $isMatched) { 
                    $RiskItems += "Unmatched MRT: $($pair.Key) (Ref: $privSvc, Pub: $pubSvc)"
                    if ($pair.PrivateApp -and -not $pair.PublicApp) {
                        $OnlyOnReference += "MRT: $($pair.Key) ($privSvc)"
                        $ReferenceRequiredMissing += "MRT: $($pair.Key)"
                    } elseif (-not $pair.PrivateApp -and $pair.PublicApp) {
                        $OnlyOnPublic += "MRT: $($pair.Key) ($pubSvc)"
                    }
                }

                $Report.Add(("{0}  MRT Key: {1}" -f $stat, $pair.Key))
                $Report.Add(("  Reference : {0,-24} -> {1}" -f $privSvc, $privRoot))
                $Report.Add(("  Public    : {0,-24} -> {1}" -f $pubSvc, $pubRoot))
            }
        } else {
            $mappingSectionOk = $false
            $Report.Add("[FAIL] No running mule_ee_* services discovered on Reference server.")
        }

        # 2. PUBLIC SERVICE CONFIGURATION & ACCOUNTS
        Add-ReportSection -Report $Report -Title "2. PUBLIC SERVER SERVICE & ACCOUNT VALIDATION"
        $Report.Add(("{0,-20} {1,-10} {2,-15} {3,-28} {4}" -f "Service", "State", "Start Mode", "Logon Account", "Status"))
        $Report.Add(("-" * 84))
        $svcSectionOk = $true
        if ($PubData.Applications.Count -gt 0) {
            foreach ($svc in $PubData.Applications) {
                $mode = if ($svc.StartMode -eq "Auto" -and $svc.DelayedAutoStart) { "Delayed Auto" } else { $svc.StartMode }
                $ok   = ($svc.State -eq "Running" -and $mode -match "Auto" -and -not [string]::IsNullOrWhiteSpace($svc.StartName))
                if (-not $ok) { $svcSectionOk = $false }
                $stat = if ($ok) { "[PASS]" } else { "[FAIL]" }
                $Report.Add(("{0,-20} {1,-10} {2,-15} {3,-28} {4}" -f $svc.ServiceName, $svc.State, $mode, $svc.StartName, $stat))
            }
        } else {
            $svcSectionOk = $false
            $Report.Add("[FAIL] No running mule_ee_* services found on public server.")
        }

        # 3. DIRECTORY, JCONN & TEMP STRUCTURE (REFERENCE-BASED)
        Add-ReportSection -Report $Report -Title "3. DIRECTORY, JCONN & TEMP STRUCTURE (REFERENCE-BASED)"
        $Report.Add(("{0,-32} {1,-42} {2}" -f "Component", "Validation Detail", "Status"))
        $Report.Add(("-" * 84))
        $folderSectionOk = $true

        foreach ($folder in @("Java8", "JConn_CPS", "Jconn_Automation", "JDA", "_SW")) {
            $pPath = if ($PrivData.FolderPaths) { $PrivData.FolderPaths[$folder] } else { $null }
            $nPath = if ($PubData.FolderPaths)  { $PubData.FolderPaths[$folder] }  else { $null }

            if ($pPath -and $nPath) {
                $status = "[PASS]"
                $detail = "Present on Reference and Public"
            } elseif (-not $pPath -and -not $nPath) {
                $status = "[PASS]"
                $detail = "Not Present On Reference Server - Not Required"
            } elseif ($pPath -and -not $nPath) {
                $status = "[FAIL]"
                $detail = "Present On Reference But Missing On Public"
                $folderSectionOk = $false
                $RiskItems += "$folder missing on Public server"
                $OnlyOnReference += "Folder: $folder"
                $ReferenceRequiredMissing += "Folder: $folder"
            } else {
                $status = "[INFO]"
                $detail = "Additional Component Found Only On Public"
                $OnlyOnPublic += "Folder: $folder"
            }
            $Report.Add(("{0,-32} {1,-42} {2}" -f "Folder: $folder", $detail, $status))
        }

        # JConn_CPS Subfolders
        $pCps = ($PrivData.CPSCount -gt 0)
        $nCps = ($PubData.CPSCount -gt 0)
        if ($pCps -and $nCps) {
            $Report.Add(("{0,-32} {1,-42} {2}" -f "Subfolders: JConn_CPS", "Populated on Reference and Public", "[PASS]"))
        } elseif (-not $pCps -and -not $nCps) {
            $Report.Add(("{0,-32} {1,-42} {2}" -f "Subfolders: JConn_CPS", "Not Present On Reference - Not Required", "[PASS]"))
        } elseif ($pCps -and -not $nCps) {
            $folderSectionOk = $false
            $Report.Add(("{0,-32} {1,-42} {2}" -f "Subfolders: JConn_CPS", "Populated On Reference But Missing On Public", "[FAIL]"))
            $RiskItems += "JConn_CPS populated on reference but empty on Public"
            $OnlyOnReference += "Subfolders: JConn_CPS"
            $ReferenceRequiredMissing += "Subfolders: JConn_CPS"
        } else {
            $Report.Add(("{0,-32} {1,-42} {2}" -f "Subfolders: JConn_CPS", "Populated Only On Public", "[INFO]"))
            $OnlyOnPublic += "Subfolders: JConn_CPS"
        }

        # Temp Root Directory
        $pTempRoot = $PrivData.TempRoot
        $nTempRoot = $PubData.TempRoot
        if ($pTempRoot -and $nTempRoot) {
            $Report.Add(("{0,-32} {1,-42} {2}" -f "Temp Root: Base Directory", "Present on Reference and Public", "[PASS]"))
        } elseif (-not $pTempRoot -and -not $nTempRoot) {
            $Report.Add(("{0,-32} {1,-42} {2}" -f "Temp Root: Base Directory", "Not Present On Reference - Not Required", "[PASS]"))
        } elseif ($pTempRoot -and -not $nTempRoot) {
            $folderSectionOk = $false
            $Report.Add(("{0,-32} {1,-42} {2}" -f "Temp Root: Base Directory", "Present On Reference But Missing On Public", "[FAIL]"))
            $RiskItems += "Temp Root folder missing on Public server"
            $OnlyOnReference += "Temp Root Directory"
            $ReferenceRequiredMissing += "Temp Root Directory"
        } else {
            $Report.Add(("{0,-32} {1,-42} {2}" -f "Temp Root: Base Directory", "Found Only On Public", "[INFO]"))
            $OnlyOnPublic += "Temp Root Directory"
        }

        # Normalized Temp Folders
        foreach ($pair in $matchedPairs) {
            $pT = $pair.PrivateApp.TempExists
            $nT = $pair.PublicApp.TempExists
            if ($pT -and $nT) {
                $Report.Add(("{0,-32} {1,-42} {2}" -f "Temp: $($pair.Key)", "Present on Reference and Public", "[PASS]"))
            } elseif (-not $pT -and -not $nT) {
                $Report.Add(("{0,-32} {1,-42} {2}" -f "Temp: $($pair.Key)", "Not Present On Reference - Not Required", "[PASS]"))
            } elseif ($pT -and -not $nT) {
                $folderSectionOk = $false
                $Report.Add(("{0,-32} {1,-42} {2}" -f "Temp: $($pair.Key)", "Present On Reference But Missing On Public", "[FAIL]"))
                $RiskItems += "Service temp folder missing for $($pair.Key) on Public"
                $OnlyOnReference += "Temp: $($pair.Key)"
                $ReferenceRequiredMissing += "Temp: $($pair.Key)"
            } else {
                $Report.Add(("{0,-32} {1,-42} {2}" -f "Temp: $($pair.Key)", "Found Only On Public", "[INFO]"))
                $OnlyOnPublic += "Temp: $($pair.Key)"
            }
        }

        # 4. ENVIRONMENT VALIDATION
        Add-ReportSection -Report $Report -Title "4. ENVIRONMENT VALIDATION"
        $Report.Add(("Java Version : {0}" -f $m.JavaVer))
        $Report.Add(("JAVA_HOME    : {0}  (Exe: {1})" -f $m.JavaHome, $m.JavaExe))
        $resStat = if ($m.CPU -lt 90 -and $m.MemUsage -lt 90 -and $m.DiskFree -gt 10) { "[PASS]" } else { "[WARNING]" }
        $Report.Add(("Resources    : CPU: {0}% | Mem: {1}% ({2} GB Free) | Disk ({3}): {4} GB Free  {5}" -f $m.CPU, $m.MemUsage, $m.FreeMem, $m.DriveName, $m.DiskFree, $resStat))
        
        $pAmq = ($PrivData.AmqFolders.Count -gt 0)
        $nAmq = ($PubData.AmqFolders.Count -gt 0)
        $amqOk = $true
        if ($pAmq -and -not $nAmq) {
            $RiskItems += "ActiveMQ present on Reference server but missing on Public"
            $OnlyOnReference += "ActiveMQ"
            $ReferenceRequiredMissing += "ActiveMQ"
            $amqOk = $false
        } elseif (-not $pAmq -and $nAmq) {
            $OnlyOnPublic += "ActiveMQ"
        }

        # ACTIVE MQ VALIDATION
        $Report.Add("")
        $Report.Add("ACTIVE MQ VALIDATION")
        $Report.Add("------------------------------------------------")
        $instStatus = if ($nAmq) { "PASS" } elseif (-not $pAmq) { "NOT REQUIRED [PASS]" } else { "FAIL" }
        $Report.Add(("Installed       : {0}" -f $instStatus))
        $listenPortsStr = if ($PubData.AmqListeningPorts.Count -gt 0) { ($PubData.AmqListeningPorts -join ", ") } else { "None" }
        $Report.Add(("Listener Ports  : {0}" -f $listenPortsStr))
        
        $suggestedUrl = $null
        $otherUrls = [System.Collections.Generic.List[string]]::new()
        foreach ($u in $AmqUrls) {
            $port = if ($u -match ':(\d+)/') { [int]$matches[1] } else { 0 }
            if ($PubData.AmqListeningPorts -contains $port -and -not $suggestedUrl) {
                $suggestedUrl = $u
            } else {
                $otherUrls.Add($u)
            }
        }
        if (-not $suggestedUrl -and $AmqUrls.Count -gt 0) {
            $suggestedUrl = $AmqUrls[0]
            if ($otherUrls.Count -gt 0) { $otherUrls.RemoveAt(0) }
        }

        $Report.Add("")
        $detectedPort = if ($PubData.AmqListeningPorts.Count -gt 0) { $PubData.AmqListeningPorts[0] } else { "None" }
        $Report.Add(("Detected Port   : {0}" -f $detectedPort))
        $Report.Add("")
        $Report.Add("Suggested URL   :")
        if ($suggestedUrl) {
            $Report.Add("  $suggestedUrl")
        }
        $Report.Add("")
        $Report.Add("Other URLs")
        $Report.Add("----------")
        foreach ($u in $otherUrls) {
            $Report.Add("  $u")
        }

        # 5. DYNAMIC WRAPPER CONFIGURATION TABLES
        $wrapperSectionOk = ($matchedPairs.Count -gt 0)
        $idx = 1
        $wrapPassCount = 0
        foreach ($pair in $matchedPairs) {
            $wOk = Add-WrapperTable -Report $Report -Title "5.$idx WRAPPER CONFIGURATION : $($pair.Key) ($($pair.PublicApp.ServiceName))" -PrivContent $pair.PrivateApp.WrapperLines -PubContent $pair.PublicApp.WrapperLines
            if ($wOk) {
                $wrapPassCount++
            } else { 
                $wrapperSectionOk = $false
                $RiskItems += "Wrapper configuration mismatch on $($pair.Key)"
            }
            $idx++
        }

        # 6. ACTIONABLE LOG FINDINGS
        Add-ReportSection -Report $Report -Title "6. ACTIONABLE LOG FINDINGS"
        $actionableLogs = @($m.LogResults | Where-Object { $_.Errors -gt 0 -or $_.Exceptions -gt 0 -or $_.Fatals -gt 0 })
        if ($actionableLogs.Count -gt 0) {
            $Report.Add(("{0,-20} {1,-30} {2,-8} {3,-8} {4,-12} {5}" -f "Application", "Log File", "Errors", "Fatals", "Exceptions", "Status"))
            $Report.Add(("-" * 84))
            foreach ($lr in $actionableLogs) {
                $Report.Add(("{0,-20} {1,-30} {2,-8} {3,-8} {4,-12} {5}" -f $lr.AppFolder, $lr.LogName, $lr.Errors, $lr.Fatals, $lr.Exceptions, "[WARNING]"))
            }
        } else {
            $Report.Add("[PASS] All scanned application log files are clean (0 Errors, 0 Fatals, 0 Exceptions).")
        }

        # 7. ESCALATION SIGNATURE ANALYSIS
        Add-ReportSection -Report $Report -Title "7. ESCALATION SIGNATURE ANALYSIS"
        $totalCritical = 0
        if ($m.CriticalList) {
            foreach ($item in $m.CriticalList) {
                $totalCritical += $item.Count
                $stat = if ($item.Count -gt 0) { "[WARNING]" } else { "[PASS]" }
                $Report.Add(("{0,-26} Count: {1,-5} {2}" -f $item.Pattern, $item.Count, $stat))
                if ($item.Count -gt 0) {
                    if (-not [string]::IsNullOrWhiteSpace($item.LogFile)) { $Report.Add(("  Found In : {0}" -f $item.LogFile)) }
                    if (-not [string]::IsNullOrWhiteSpace($item.Sample))  { $Report.Add(("  Sample   : {0}" -f $item.Sample)) }
                }
            }
        }
        if ($totalCritical -gt 0) {
            $RiskItems += "$totalCritical critical log signatures detected"
        }

        # 8. REFERENCE DIFFERENCES
        Add-ReportSection -Report $Report -Title "8. REFERENCE DIFFERENCES"
        $Report.Add("Only On Reference:")
        if ($OnlyOnReference.Count -eq 0) { $Report.Add("  None") } else { foreach ($item in $OnlyOnReference) { $Report.Add("  - $item") } }

        $Report.Add("")
        $Report.Add("Only On Public:")
        if ($OnlyOnPublic.Count -eq 0) { $Report.Add("  None") } else { foreach ($item in $OnlyOnPublic) { $Report.Add("  - $item") } }

        $Report.Add("")
        $Report.Add("Reference-Required Missing On Public:")
        if ($ReferenceRequiredMissing.Count -eq 0) { $Report.Add("  None") } else { foreach ($item in $ReferenceRequiredMissing) { $Report.Add("  - $item") } }

        # 9. CUTOVER RISK SUMMARY
        Add-ReportSection -Report $Report -Title "9. CUTOVER RISK SUMMARY"
        $FailCount = @($Report | Where-Object { $_ -match "\[FAIL\]" }).Count
        
        $riskLevel = "LOW"
        if ($FailCount -ge 4) { $riskLevel = "HIGH" }
        elseif ($FailCount -gt 0 -or $totalCritical -gt 0) { $riskLevel = "MEDIUM" }
        elseif ($RiskItems.Count -gt 0) { $riskLevel = "LOW (WITH WARNINGS)" }

        $Report.Add("HIGH RISK FINDINGS")
        $Report.Add("------------------")
        if ($RiskItems.Count -eq 0) { $Report.Add("None detected.") } else { foreach ($ri in $RiskItems) { $Report.Add(" - $ri") } }

        $Report.Add("")
        $Report.Add("OVERALL RISK LEVEL")
        $Report.Add("------------------")
        $Report.Add($riskLevel)

        # Log Warnings Summary
        $appWarningCount = (
            $actionableLogs |
            Select-Object AppFolder -Unique
        ).Count

        # 10. MIGRATION SUMMARY
        Add-ReportSection -Report $Report -Title "10. MIGRATION SUMMARY"
        $Report.Add(("Reference Running MRTs         : {0}" -f $PrivData.Applications.Count))
        $Report.Add(("Public Running MRTs            : {0}" -f $PubData.Applications.Count))
        $Report.Add(("Matched MRTs                   : {0}" -f $matchedPairs.Count))
        $Report.Add(("Applications With Log Warnings : {0}" -f $appWarningCount))
        $Report.Add(("Wrapper Matches                : {0}/{1}" -f $wrapPassCount, $matchedPairs.Count))
        $Report.Add("Wrapper Custom Properties Checked : 4")
        $Report.Add(("Service Matches                : {0}/{1}" -f $PubData.Applications.Count, $PubData.Applications.Count))
        $Report.Add(("Critical Errors Found          : {0}" -f $totalCritical))
        $Report.Add(("Reference Differences          : {0}" -f ($OnlyOnReference.Count + $OnlyOnPublic.Count)))

        # 11. CUTOVER DECISION MATRIX
        Add-ReportSection -Report $Report -Title "11. CUTOVER DECISION MATRIX"
        $Report.Add(("{0,-26} : {1}" -f "MRT Discovery", $(if ($mappingSectionOk) { "PASS" } else { "FAIL" })))
        $Report.Add(("{0,-26} : {1}" -f "Public Services", $(if ($svcSectionOk) { "PASS" } else { "FAIL" })))
        $Report.Add(("{0,-26} : {1}" -f "Folders & Temp", $(if ($folderSectionOk) { "PASS" } else { "FAIL" })))
        $Report.Add(("{0,-26} : {1}" -f "Environment & Java", $(if ($resStat -match "PASS" -and $amqOk) { "PASS" } else { "WARNING" })))
        $Report.Add(("{0,-26} : {1}" -f "Wrapper Configuration", $(if ($wrapperSectionOk) { "PASS" } else { "FAIL" })))
        $Report.Add(("{0,-26} : {1}" -f "Escalation Signatures", $(if ($totalCritical -eq 0) { "PASS" } else { "WARNING" })))
        
        $recommendation = if ($FailCount -eq 0 -and $RiskItems.Count -eq 0) {
            "READY FOR CUTOVER"
        } elseif ($FailCount -eq 0) {
            "READY FOR CUTOVER WITH WARNINGS"
        } else {
            "REVIEW REQUIRED BEFORE CUTOVER"
        }

        $Report.Add("")
        $Report.Add("Decision")
        $Report.Add("--------")
        $Report.Add($recommendation)

        # 12. FINAL SIGN-OFF
        $Duration = [math]::Round(((Get-Date) - $ValidationStart).TotalSeconds, 2)
        $Report.Add("")
        $Report.Add("====================================================================================")
        $Report.Add(("MIGRATION READINESS SIGN-OFF                             [DURATION: {0} SECONDS]" -f $Duration))
        $Report.Add("====================================================================================")
        $Report.Add(("  {0} Dynamic MRT Discovery & Mapping" -f $(if ($mappingSectionOk) { "[OK]" } else { "[FAIL]" })))
        $Report.Add(("  {0} Public Services & Logon Accounts" -f $(if ($svcSectionOk) { "[OK]" } else { "[FAIL]" })))
        $Report.Add(("  {0} Directory, JConn & Temp Structure (Reference-Based)" -f $(if ($folderSectionOk) { "[OK]" } else { "[FAIL]" })))
        $Report.Add(("  {0} Environment & Java Validation" -f $(if ($resStat -match "PASS" -and $amqOk) { "[OK]" } else { "[WARNING]" })))
        $Report.Add(("  {0} Wrapper Memory & JMX Configuration" -f $(if ($wrapperSectionOk) { "[OK]" } else { "[FAIL]" })))
        $Report.Add(("  {0} Escalation Signatures ({1} Detected)" -f $(if ($totalCritical -eq 0) { "[OK]" } else { "[WARNING]" }), $totalCritical))
        $Report.Add("")
        $Report.Add(("FINAL RESULT : {0} ({1} Failures Detected)" -f $recommendation, $FailCount))
        $Report.Add("====================================================================================")

        $output.Text = $Report -join [Environment]::NewLine
        $progressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $progressBar.Value = 100
        $progressBar.Visible = $true
        $statusPill.Text = "[ COMPLETED ]"
        $statusPill.ForeColor = if ($FailCount -eq 0) { [System.Drawing.Color]::LimeGreen } else { [System.Drawing.Color]::IndianRed }
        $statusText.Text = "Validation finished in $Duration seconds"

        $script:LastReportData = @{
            Customer                 = $txtCustomer.Text
            INC                      = $txtINC.Text
            ReferenceServer          = $OldServer
            PublicServer             = $NewServer
            Duration                 = $Duration
            Timestamp                = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            MatchedPairs             = $matchedPairs
            PrivData                 = $PrivData
            PubData                  = $PubData
            Metrics                  = $m
            FailCount                = $FailCount
            TotalCritical            = $totalCritical
            RiskLevel                = $riskLevel
            Recommendation           = $recommendation
            RiskItems                = $RiskItems
            OnlyOnReference          = $OnlyOnReference
            OnlyOnPublic             = $OnlyOnPublic
            ReferenceRequiredMissing = $ReferenceRequiredMissing
            ActionableLogs           = $actionableLogs
            MappingOk                = $mappingSectionOk
            SvcOk                    = $svcSectionOk
            FolderOk                 = $folderSectionOk
            EnvOk                    = ($resStat -match "PASS" -and $amqOk)
            WrapperOk                = $wrapperSectionOk
            WrapperPassCount         = $wrapPassCount
            WrapperTotalCount        = $matchedPairs.Count
            AmqUrls                  = $AmqUrls
            FullReportText           = $output.Text
        }
    } catch {
        $output.Text = @"
VALIDATION FAILED

MESSAGE:
$($_.Exception.Message)

LINE:
$($_.InvocationInfo.ScriptLineNumber)

COMMAND:
$($_.InvocationInfo.Line)
"@
        $progressBar.Value = 0
        $progressBar.Visible = $false
        $statusPill.Text = "[ ERROR ]"
        $statusPill.ForeColor = [System.Drawing.Color]::Red
        $statusText.Text = "Validation execution failed"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnRun.Enabled = $true
    }
})

# ==========================================================
# EXECUTIVE HTML REPORT EXPORT (WITH PRINT & AUTO-COLLAPSE)
# ==========================================================

$btnExportHtml.Add_Click({
    if ([string]::IsNullOrWhiteSpace($output.Text) -or $null -eq $script:LastReportData) {
        [System.Windows.Forms.MessageBox]::Show("There is no report to export. Run validation first.", "Nothing to Export") | Out-Null
        return
    }
    try {
        $data = $script:LastReportData
        $m    = $data.Metrics
        $cust = if ($data.Customer.Trim()) { ($data.Customer.Trim() -replace '[^\w\-]', '_') } else { "Cust" }
        $inc  = if ($data.INC.Trim())      { ($data.INC.Trim() -replace '[^\w\-]', '') }       else { "INC" }
        $file = Join-Path $env:USERPROFILE ("Desktop\P2PValidation_v80_${cust}_${inc}_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".html")
        
        $recClass = "badge-ok"
        if ($data.Recommendation -match "WARNINGS") { $recClass = "badge-warn" }
        elseif ($data.Recommendation -match "REVIEW") { $recClass = "badge-fail" }

        $riskColor = "#34d399"
        if ($data.RiskLevel -match "HIGH") { $riskColor = "#f87171" }
        elseif ($data.RiskLevel -match "MEDIUM") { $riskColor = "#fbbf24" }

        # Smart Action Box
        $actionItems = @()
        $critFound = @($m.CriticalList | Where-Object { $_.Count -gt 0 })
        if ($critFound.Count -gt 0) {
            foreach ($c in $critFound) {
                $loc = if ($c.LogFile) { " (Found In: $($c.LogFile))" } else { "" }
                $actionItems += "Review <strong>$($c.Pattern)</strong> occurrences$loc"
            }
        } else {
            $actionItems += "<span style='color:#34d399;'>&check; No Escalation Signatures Detected</span>"
        }
        if (-not $data.WrapperOk) {
            $actionItems += "Review wrapper.conf property discrepancies flagged in Section 5"
        } else {
            $actionItems += "<span style='color:#34d399;'>&check; No Wrapper Issues Detected</span>"
        }
        $totalDiffs = $data.OnlyOnReference.Count + $data.OnlyOnPublic.Count
        $appWarningCount = ($data.ActionableLogs | Select-Object AppFolder -Unique).Count
        if ($totalDiffs -gt 0 -and $data.ReferenceRequiredMissing.Count -gt 0) {
            $actionItems += "Resolve missing reference components on Public: $($data.ReferenceRequiredMissing -join ', ')"
        } else {
            $actionItems += "<span style='color:#34d399;'>&check; No Reference Differences Detected</span>"
        }

        # ActiveMQ Environment Badges in AMQ Grid
        $amqRowsHtml = ""
        if ($data.PubData.AmqFolders.Count -gt 0) {
            $listeningSet = @($data.PubData.AmqListeningPorts)
            foreach ($u in $data.AmqUrls) {
                $port = if ($u -match ':(\d+)/') { [int]$matches[1] } else { 0 }
                $envLabel = switch ($port) {
                    11080 { "PROD" }
                    31080 { "QA" }
                    51080 { "DEV" }
                    default { "PORT $port" }
                }
                $isListening = ($listeningSet -contains $port)
                if ($isListening) {
                    $amqRowsHtml += "<a href='$u' target='_blank' class='amq-row listening'><span class='amq-env ae-qa'>$envLabel</span><span class='amq-url-text'>$u</span><span class='amq-status-tag'><span class='live-dot'></span> LISTENING</span></a>"
                } else {
                    $aeClass = if ($envLabel -eq "PROD") { "ae-prod" } else { "ae-dev" }
                    $amqRowsHtml += "<a href='$u' target='_blank' class='amq-row'><span class='amq-env $aeClass'>$envLabel</span><span class='amq-url-text'>$u</span></a>"
                }
            }
        } else {
            $amqRowsHtml = "<div style='color:#9ca3af;font-size:12px;padding:8px 0;'>ActiveMQ is not installed on Public server.</div>"
        }

        # Services Rows
        $svcRows = ""
        foreach ($s in $data.PubData.Applications) {
            $mode = if ($s.StartMode -eq "Auto" -and $s.DelayedAutoStart) { "Delayed Auto" } else { $s.StartMode }
            $ok = ($s.State -eq "Running" -and $mode -match "Auto" -and -not [string]::IsNullOrWhiteSpace($s.StartName))
            $st = if ($ok) { '<span class="badge b-pass">PASS</span>' } else { '<span class="badge b-fail">FAIL</span>' }
            $svcRows += "<tr><td style='font-weight:700;'>$($s.ServiceName)</td><td><span class='badge b-run'>$($s.State)</span></td><td>$mode</td><td class='cell-mono'>$($s.StartName)</td><td>$st</td></tr>"
        }

        # Critical Rows
        $critRows = ""
        foreach ($ci in $m.CriticalList) {
            $st = if ($ci.Count -gt 0) { '<span class="badge b-warn">WARN</span>' } else { '<span class="badge b-pass">PASS</span>' }
            $sev = switch -wildcard ($ci.Pattern) {
                "*OutOfMemory*" { "CRITICAL" }
                "*ORA-*"        { "CRITICAL" }
                "*FileNotFound*" { "MEDIUM" }
                default         { "HIGH" }
            }
            $fileLabel = if ($ci.Count -gt 0 -and $ci.LogFile) { "<span class='cell-mono' style='margin-left:8px;'>$($ci.LogFile)</span>" } else { "" }
            $samp = if ($ci.Count -gt 0 -and $ci.Sample) { "<br><span style='color:#fca5a5;font-size:11px;font-family:Consolas,monospace;'>Sample: $([System.Net.WebUtility]::HtmlEncode($ci.Sample))</span>" } else { "" }
            $critRows += "<tr><td class='cell-mono'><strong>$($ci.Pattern)</strong></td><td>$($ci.Count)</td><td>$sev</td><td>$st $fileLabel $samp</td></tr>"
        }

        # Actionable Log Rows with visual breakdown bar
        $logRows = ""
        if ($data.ActionableLogs.Count -gt 0) {
            foreach ($lr in $data.ActionableLogs) {
                $errBar = ""
                if ($lr.Errors -gt 0) {
                    $w = [Math]::Min(60, [Math]::Max(20, $lr.Errors))
                    $errBar += "<span class='es-err err-seg' style='width:${w}px;'>$($lr.Errors)</span>"
                }
                if ($lr.Fatals -gt 0) {
                    $w = [Math]::Min(60, [Math]::Max(20, $lr.Fatals))
                    $errBar += "<span class='es-fat err-seg' style='width:${w}px;'>$($lr.Fatals)</span>"
                }
                if ($lr.Exceptions -gt 0) {
                    $w = [Math]::Min(60, [Math]::Max(20, $lr.Exceptions))
                    $errBar += "<span class='es-exc err-seg' style='width:${w}px;'>$($lr.Exceptions)</span>"
                }
                if ([string]::IsNullOrEmpty($errBar)) {
                    $errBar = "<span style='color:#6b7280;font-size:11px;'>Clean</span>"
                }
                $logRows += "<tr><td style='font-weight:700;'>$($lr.AppFolder)</td><td class='cell-mono'>$($lr.LogName)</td><td>$($lr.Errors)</td><td>$($lr.Fatals)</td><td>$($lr.Exceptions)</td><td><div class='err-bar'>$errBar</div></td><td><span class='badge b-warn'>WARN</span></td></tr>"
            }
        } else {
            $logRows = "<tr><td colspan='7' style='text-align:center;color:#34d399;padding:16px;'>All scanned application logs are clean (0 Errors, 0 Fatals, 0 Exceptions)</td></tr>"
        }

        $totalDiffs = $data.OnlyOnReference.Count + $data.OnlyOnPublic.Count
        $appWarningCount = ($data.ActionableLogs | Select-Object AppFolder -Unique).Count

        # Customer / INC Display
        $custDisplay = if ([string]::IsNullOrWhiteSpace($data.Customer)) { "Cust" } else { [System.Net.WebUtility]::HtmlEncode($data.Customer) }
        $incDisplay  = if ([string]::IsNullOrWhiteSpace($data.INC)) { "N/A (Optional)" } else { [System.Net.WebUtility]::HtmlEncode($data.INC) }

        # Heatmap status
        $mrtHeatClass  = if ($data.MappingOk) { "heat-pass" } else { "heat-fail" }
        $mrtHeatText   = "$($data.MatchedPairs.Count) / $($data.PrivData.Applications.Count) Matched"
        $svcHeatClass  = if ($data.SvcOk) { "heat-pass" } else { "heat-fail" }
        $svcHeatText   = "$($data.PubData.Applications.Count) / $($data.PubData.Applications.Count) Running"
        $dirHeatClass  = if ($data.FolderOk) { "heat-pass" } else { "heat-fail" }
        $envHeatClass  = if ($data.EnvOk) { "heat-pass" } else { "heat-warn" }
        $wrapHeatClass = if ($data.WrapperOk) { "heat-pass" } else { "heat-fail" }
        $wrapHeatText  = "$($data.WrapperPassCount) / $($data.MatchedPairs.Count) PASS"
        $critHeatClass = if ($data.TotalCritical -eq 0) { "heat-pass" } else { "heat-warn" }
        $critHeatText  = if ($data.TotalCritical -eq 0) { "0 Signatures" } else { "$($data.TotalCritical) Found" }

        $safeFullText = [System.Net.WebUtility]::HtmlEncode($data.FullReportText)
        $safeFullText = $safeFullText -replace '\[PASS\]', '<span class="p-pass">PASS</span>'
        $safeFullText = $safeFullText -replace '\[FAIL\]', '<span class="badge b-fail">FAIL</span>'
        $safeFullText = $safeFullText -replace '\[WARNING\]', '<span class="p-warn">WARN</span>'
        $safeFullText = $safeFullText -replace '\[INFO\]', '<span class="badge b-run">INFO</span>'
        $safeFullText = $safeFullText -replace '\[OK\]', '<span class="p-pass">OK</span>'

        # Generate Action Checklist HTML
        $actionItemsHtml = ""
        foreach ($ai in $actionItems) {
            $actionItemsHtml += "<div class='check-item'><span class='check-icon'>&#10003;</span><span>$ai</span></div>"
        }

        # Generate Interactive Wrapper Config Cards HTML
        $wrapCardsHtml = "<div class='wrapper-grid'>"
        foreach ($pair in $data.MatchedPairs) {
            $pubApp = $pair.PublicApp
            $pu = Parse-WrapperConf -Content $pubApp.WrapperLines
            $isSvc = ($pair.Key -eq "GGSVC")
            $cardClass = if ($isSvc) { "wrap-card wrap-special" } else { "wrap-card" }
            $headerBg = if ($isSvc) { "background:#064e3b;" } else { "" }
            $headerColor = if ($isSvc) { "color:#ecfdf5;" } else { "" }
            $svcSubColor = if ($isSvc) { "color:#a7f3d0;" } else { "" }
            
            $wrapCardsHtml += "<div class='$cardClass'>"
            $wrapCardsHtml += "  <div class='wrap-card-header' style='$headerBg'>"
            $wrapCardsHtml += "    <span class='wrap-card-title' style='$headerColor'>$($pair.Key)</span>"
            $wrapCardsHtml += "    <span class='wrap-card-svc' style='$svcSubColor'>$($pubApp.ServiceName)</span>"
            $wrapCardsHtml += "  </div>"
            $wrapCardsHtml += "  <div class='wrap-prop-row'><span class='wrap-prop-name'>Memory (Init / Max)</span><span class='wrap-prop-val'>$($pu.InitMemory) / $($pu.MaxMemory) MB</span></div>"
            $wrapCardsHtml += "  <div class='wrap-prop-row'><span class='wrap-prop-name'>Metaspace (Init / Max)</span><span class='wrap-prop-val'>$($pu.MetaspaceSize) / $($pu.MaxMetaspaceSize)</span></div>"
            $wrapCardsHtml += "  <div class='wrap-prop-row'><span class='wrap-prop-name'>JMX &amp; RMI Port</span><span class='wrap-prop-val'>$($pu.JmxPort) / $($pu.RmiPort)</span></div>"
            if ($isSvc) {
                $deploySt = if ($pu.MuleDeployApplications -eq "connect-config-service") { "<span style='color:#34d399;'>connect-config-service [PASS]</span>" } else { "<span style='color:#f87171;'>$($pu.MuleDeployApplications) [FAIL]</span>" }
                $wrapCardsHtml += "  <div class='wrap-prop-row' style='background:rgba(16,185,129,0.15);'><span class='wrap-prop-name' style='color:#34d399;font-weight:800;'>MuleDeployApplications</span><span class='wrap-prop-val'>$deploySt</span></div>"
            }
            $wrapCardsHtml += "  <div class='wrap-prop-row'><span class='wrap-prop-name'>Oracle JDBC Compliant</span><span class='wrap-prop-val' style='color:#34d399;'>$($pu.OracleJdbcCompliance) [PASS]</span></div>"
            $tmpStatus = if ($pu.JavaTmpDir -notin @('Missing','Not Configured')) { "<span style='color:#34d399;'>Configured [PASS]</span>" } else { "Not Set (Matched)" }
            $wrapCardsHtml += "  <div class='wrap-prop-row'><span class='wrap-prop-name'>JavaTmpDir</span><span class='wrap-prop-val'>$tmpStatus</span></div>"
            $wrapCardsHtml += "</div>"
        }
        $wrapCardsHtml += "</div>"

        $htmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>P2P Migration Cutover Decision - $($data.Customer)</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  
  :root {
    --bg-page: #030712;
    --bg-card: #111827;
    --bg-card-hover: #1f2937;
    --bg-subtle: #0f172a;
    --border-color: #1f2937;
    --border-highlight: #374151;
    --text-primary: #f9fafb;
    --text-secondary: #9ca3af;
    --text-muted: #6b7280;
    --emerald-main: #10b981;
    --emerald-glow: rgba(16, 185, 129, 0.22);
    --hero-bg: linear-gradient(135deg, #022c22 0%, #064e3b 50%, #065f46 100%);
    --heat-pass-bg: #022c22;
    --heat-pass-bdr: #059669;
    --heat-pass-txt: #34d399;
    --badge-pass-bg: #064e3b;
    --badge-pass-txt: #34d399;
    --badge-pass-bdr: #059669;
    --badge-warn-bg: #451a03;
    --badge-warn-txt: #fde68a;
    --badge-warn-bdr: #b45309;
    --badge-fail-bg: #450a0a;
    --badge-fail-txt: #f87171;
    --badge-fail-bdr: #b91c1c;
    --tab-active-bg: #111827;
    --tab-active-txt: #34d399;
    --terminal-bg: #050811;
  }

  body {
    font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
    background: var(--bg-page);
    color: var(--text-primary);
    min-height: 100vh;
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
    text-rendering: optimizeLegibility;
  }

  /* ── Hero Banner ─────────────────────────────────────── */
  .hero {
    background: var(--hero-bg);
    padding: 24px 20px 22px;
    color: #fff;
    border-bottom: 2px solid var(--emerald-main);
  }
  .hero-inner {
    max-width: min(1360px, 94vw);
    margin: 0 auto;
    width: 100%;
  }
  .hero-top {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
    flex-wrap: wrap;
    gap: 10px;
  }
  .hero-brand {
    font-size: 13px;
    font-weight: 800;
    letter-spacing: 1.5px;
    text-transform: uppercase;
    color: #6ee7b7;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .hero-meta {
    display: flex;
    align-items: center;
    gap: 16px;
    font-size: 12px;
    color: #a7f3d0;
    flex-wrap: wrap;
  }
  .hero-meta strong { color: #ecfdf5; }

  .hero-content {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    gap: 24px;
    flex-wrap: wrap;
  }
  .hero-verdict-text {
    font-size: clamp(26px, 3.2vw, 36px);
    font-weight: 900;
    letter-spacing: -0.5px;
    line-height: 1.1;
    color: #ecfdf5;
    text-shadow: 0 0 20px rgba(52, 211, 153, 0.4);
  }
  .hero-sub {
    font-size: 12.5px;
    color: #a7f3d0;
    margin-top: 8px;
    letter-spacing: 0.5px;
  }
  .hero-stats {
    display: flex;
    gap: 12px;
    flex-wrap: wrap;
  }
  .hero-stat {
    text-align: center;
    min-width: 84px;
    background: rgba(0, 0, 0, 0.35);
    padding: 10px 14px;
    border-radius: 8px;
    border: 1px solid rgba(255, 255, 255, 0.12);
    flex: 1 1 auto;
  }
  .hero-stat-value {
    font-size: 22px;
    font-weight: 900;
    line-height: 1;
    color: #34d399;
  }
  .hero-stat-label {
    font-size: 10.5px;
    font-weight: 800;
    letter-spacing: 1px;
    text-transform: uppercase;
    color: #a7f3d0;
    margin-top: 5px;
  }

  /* ── Container ───────────────────────────────────────── */
  .container { max-width: min(1360px, 94vw); margin: 0 auto; padding: 24px 20px 60px; }

  /* ── Identification Strip ────────────────────────────── */
  .id-strip {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
    border: 1px solid var(--border-color);
    border-radius: 12px;
    overflow: hidden;
    margin-bottom: 22px;
    background: var(--bg-card);
  }
  .id-cell {
    padding: 14px 18px;
    border-right: 1px solid var(--border-color);
    border-bottom: 1px solid var(--border-color);
  }
  .id-cell:last-child { border-right: none; }
  .id-label {
    font-size: 11px;
    font-weight: 800;
    letter-spacing: 1px;
    text-transform: uppercase;
    color: var(--text-muted);
    margin-bottom: 5px;
  }
  .id-value { font-size: 14px; font-weight: 800; color: var(--text-primary); }
  .id-value.mono { font-family: 'Cascadia Code', Consolas, monospace; font-size: 13px; color: #38bdf8; }
  .id-value.green { color: var(--emerald-main); }

  /* ── Status Heatmap ──────────────────────────────────── */
  .heatmap {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
    gap: 12px;
    margin-bottom: 22px;
  }
  .heat-cell {
    border-radius: 10px;
    padding: 16px 14px;
    text-align: center;
    background: var(--heat-pass-bg);
    border: 1.5px solid var(--heat-pass-bdr);
    box-shadow: 0 0 16px var(--emerald-glow);
  }
  .heat-icon {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-size: 15px;
    font-weight: 900;
    margin-bottom: 8px;
    background: var(--emerald-main);
    color: #022c22;
  }
  .heat-name {
    font-size: 12px;
    font-weight: 800;
    color: var(--text-primary);
    margin-bottom: 4px;
  }
  .heat-detail {
    font-size: 11.5px;
    font-weight: 700;
    color: var(--heat-pass-txt);
  }

  /* ── 3-Column Layout (Scope, Checklist, AMQ) ────────── */
  .cols-3 {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
    gap: 18px;
    margin-bottom: 22px;
    align-items: stretch;
  }

  .cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: 20px; margin-bottom: 22px; align-items: start; }
  @media (max-width: 500px) { .cols, .cols-3 { grid-template-columns: 1fr; } }

  .section {
    border: 1px solid var(--border-color);
    border-radius: 12px;
    overflow: hidden;
    background: var(--bg-card);
    display: flex;
    flex-direction: column;
  }
  .section-head {
    padding: 13px 18px;
    font-size: 11.5px;
    font-weight: 800;
    color: var(--text-muted);
    background: var(--bg-subtle);
    border-bottom: 1px solid var(--border-color);
    letter-spacing: 1px;
    text-transform: uppercase;
  }
  .section-body { padding: 16px 18px; flex: 1; }

  /* Checklist / Action Required Items */
  .checklist-grid { display: flex; flex-direction: column; gap: 8px; }
  .check-item {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 12px;
    background: var(--bg-subtle);
    border: 1px solid var(--border-color);
    border-radius: 8px;
    font-size: 12px;
    font-weight: 600;
  }
  .check-icon {
    width: 20px;
    height: 20px;
    border-radius: 50%;
    background: #064e3b;
    color: #34d399;
    border: 1px solid #059669;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 11px;
    font-weight: 900;
    flex-shrink: 0;
  }

  /* Wrapper Config Cards */
  .wrapper-grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(380px, 1fr));
    gap: 16px;
  }
  .wrap-card {
    border: 1px solid var(--border-color);
    border-radius: 10px;
    overflow: hidden;
    background: var(--bg-subtle);
  }
  .wrap-card-header {
    padding: 10px 14px;
    background: #111827;
    border-bottom: 1px solid var(--border-color);
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .wrap-card-title {
    font-weight: 800;
    font-size: 12.5px;
    color: var(--text-primary);
  }
  .wrap-card-svc {
    font-family: 'Cascadia Code', Consolas, monospace;
    font-size: 11px;
    color: #94a3b8;
  }
  .wrap-prop-row {
    display: flex;
    justify-content: space-between;
    padding: 6px 12px;
    font-size: 11px;
    border-bottom: 1px solid #1e293b;
  }
  .wrap-prop-row:last-child { border-bottom: none; }
  .wrap-prop-name { color: #94a3b8; font-weight: 600; }
  .wrap-prop-val { font-family: 'Cascadia Code', Consolas, monospace; color: #f1f5f9; font-weight: 700; }
  .wrap-special {
    background: rgba(16, 185, 129, 0.08);
    border-left: 3px solid var(--emerald-main);
  }

  /* Scope Tags */
  .scope-tags { display: flex; flex-wrap: wrap; gap: 8px; }
  .scope-tag {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    font-size: 12px;
    font-weight: 700;
    color: var(--text-primary);
    background: var(--bg-subtle);
    border-radius: 6px;
    border: 1px solid var(--border-color);
  }
  .scope-tag .dot { color: var(--emerald-main); font-size: 13px; }

  /* AMQ Grid */
  .amq-grid { display: flex; flex-direction: column; gap: 8px; }
  .amq-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 9px 14px;
    border-radius: 8px;
    border: 1px solid var(--border-color);
    background: var(--bg-subtle);
    text-decoration: none;
    transition: all 0.15s;
    font-size: 12.5px;
  }
  .amq-row:hover { background: var(--bg-card-hover); border-color: var(--emerald-main); }
  .amq-row.listening {
    background: var(--heat-pass-bg);
    border-color: var(--heat-pass-bdr);
    box-shadow: 0 0 14px var(--emerald-glow);
  }
  .amq-env {
    font-size: 10px;
    font-weight: 900;
    letter-spacing: 0.5px;
    padding: 3px 8px;
    border-radius: 4px;
    min-width: 40px;
    text-align: center;
  }
  .ae-prod { background: #450a0a; color: #f87171; border: 1px solid #7f1d1d; }
  .ae-qa   { background: #064e3b; color: #34d399; border: 1px solid #059669; }
  .ae-dev  { background: #172554; color: #93c5fd; border: 1px solid #1e40af; }
  .amq-url-text {
    font-family: 'Cascadia Code', Consolas, monospace;
    font-size: 12.5px;
    color: var(--text-secondary);
    flex: 1;
    word-break: break-all;
  }
  .amq-row.listening .amq-url-text { color: var(--heat-pass-txt); font-weight: 700; }
  .amq-status-tag {
    font-size: 10px;
    font-weight: 900;
    color: var(--emerald-main);
    display: flex;
    align-items: center;
    gap: 6px;
    letter-spacing: 0.5px;
  }
  .live-dot {
    display: inline-block;
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--emerald-main);
  }

  /* ── Tabbed Detail View ──────────────────────────── */
  .tabs-container {
    border: 1px solid var(--border-color);
    border-radius: 12px;
    overflow: hidden;
    background: var(--bg-card);
    margin-bottom: 24px;
  }
  .tabs-nav {
    display: flex;
    background: var(--bg-subtle);
    border-bottom: 1px solid var(--border-color);
    overflow-x: auto;
  }
  .tab-btn {
    padding: 13px 20px;
    font-size: 12.5px;
    font-weight: 700;
    color: var(--text-secondary);
    cursor: pointer;
    border: none;
    background: none;
    border-bottom: 2px solid transparent;
    white-space: nowrap;
    transition: all 0.15s;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .tab-btn:hover { color: var(--text-primary); background: var(--bg-card-hover); }
  .tab-btn.active {
    color: var(--tab-active-txt);
    border-bottom-color: var(--emerald-main);
    background: var(--tab-active-bg);
  }
  .tab-pane { display: none; padding: 22px; }
  .tab-pane.active { display: block; }

  /* Badges */
  .badge {
    display: inline-block;
    padding: 3px 9px;
    border-radius: 20px;
    font-size: 10.5px;
    font-weight: 800;
    letter-spacing: 0.3px;
  }
  .b-pass { background: var(--badge-pass-bg); color: var(--badge-pass-txt); border: 1px solid var(--badge-pass-bdr); }
  .b-warn { background: var(--badge-warn-bg); color: var(--badge-warn-txt); border: 1px solid var(--badge-warn-bdr); }
  .b-fail { background: var(--badge-fail-bg); color: var(--badge-fail-txt); border: 1px solid var(--badge-fail-bdr); }
  .b-run  { background: #0c4a6e; color: #38bdf8; border: 1px solid #0284c7; }
  .b-count {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    min-width: 19px;
    height: 19px;
    border-radius: 10px;
    font-size: 10px;
    font-weight: 800;
    padding: 0 5px;
  }
  .bc-warn { background: var(--badge-warn-bg); color: var(--badge-warn-txt); border: 1px solid var(--badge-warn-bdr); }
  .bc-pass { background: var(--badge-pass-bg); color: var(--badge-pass-txt); border: 1px solid var(--badge-pass-bdr); }

  /* Clean Banner */
  .clean-row {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 16px;
    background: var(--badge-pass-bg);
    border: 1px solid var(--badge-pass-bdr);
    border-radius: 8px;
    font-size: 13px;
    color: var(--badge-pass-txt);
    font-weight: 700;
  }

  /* ── Tables ───────────────────────────────────────────── */
  table { width: 100%; border-collapse: collapse; font-size: 12.5px; }
  th {
    text-align: left;
    padding: 10px 14px;
    font-size: 11px;
    font-weight: 800;
    letter-spacing: 0.5px;
    text-transform: uppercase;
    color: var(--text-muted);
    border-bottom: 1px solid var(--border-color);
  }
  td { padding: 11px 14px; border-bottom: 1px solid var(--border-color); color: var(--text-primary); }
  tr:last-child td { border-bottom: none; }
  tbody tr:hover td { background: var(--bg-subtle); }
  .cell-mono { font-family: 'Cascadia Code', Consolas, monospace; font-size: 12px; color: #38bdf8; }

  /* Error bars inside table */
  .err-bar { display: flex; align-items: center; gap: 3px; height: 18px; }
  .err-seg {
    height: 100%;
    border-radius: 3px;
    min-width: 8px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 8.5px;
    font-weight: 800;
    color: #fff;
    padding: 0 4px;
  }
  .es-err { background: #ef4444; }
  .es-fat { background: #a855f7; }
  .es-exc { background: #f59e0b; }

  /* ── PowerShell Console Terminal Window ───────────────── */
  .ps-terminal-window {
    background: #050811;
    border: 1px solid #1e293b;
    border-radius: 12px;
    overflow: hidden;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.7);
  }
  .ps-terminal-header {
    background: #0d1527;
    border-bottom: 1px solid #1e293b;
    padding: 10px 18px;
    display: flex;
    justify-content: space-between;
    align-items: center;
  }
  .ps-tab {
    display: flex;
    align-items: center;
    gap: 8px;
    background: #1e293b;
    padding: 4px 12px;
    border-radius: 6px;
    font-family: 'Cascadia Code', Consolas, monospace;
    font-size: 11.5px;
    color: #38bdf8;
    font-weight: 700;
  }
  .ps-tab-prompt { color: #10b981; }
  .ps-actions { display: flex; align-items: center; gap: 10px; }
  .ps-btn {
    background: #111827;
    border: 1px solid #374151;
    color: #e5e7eb;
    font-size: 11px;
    font-weight: 700;
    padding: 5px 12px;
    border-radius: 6px;
    cursor: pointer;
    transition: all 0.15s;
  }
  .ps-btn:hover { background: #1f2937; border-color: #38bdf8; color: #38bdf8; }

  .ps-terminal-body {
    padding: 16px 20px;
    max-height: 560px;
    overflow-y: auto;
    overflow-x: auto;
    scrollbar-width: thin;
    scrollbar-color: #374151 #050811;
  }
  .ps-terminal-body::-webkit-scrollbar { width: 8px; height: 8px; }
  .ps-terminal-body::-webkit-scrollbar-thumb { background: #374151; border-radius: 4px; }
  .ps-terminal-body::-webkit-scrollbar-track { background: #050811; }

  pre.ps-code {
    font-family: 'Cascadia Code', 'Consolas', monospace;
    font-size: 12px;
    line-height: 1.6;
    color: #d1d5db;
    margin: 0;
    white-space: pre;
  }

  .p-pass { background: #064e3b; color: #34d399; font-weight: 800; padding: 1px 6px; border-radius: 3px; }
  .p-warn { background: #451a03; color: #fbbf24; font-weight: 800; padding: 1px 6px; border-radius: 3px; }

  /* ── Footer ──────────────────────────────────────────── */
  .footer {
    text-align: center;
    padding: 24px;
    font-size: 11px;
    color: var(--text-muted);
    border-top: 1px solid var(--border-color);
  }

  /* ── Print: Strict 2-Page Certificate ───────────────── */
  @media print {
    @page { size: A4 portrait; margin: 10mm 12mm; }
    body { background: #fff !important; color: #000 !important; }
    .hero { background: #064e3b !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
    .id-strip, .section, .tabs-container { border: 1px solid #ccc !important; box-shadow: none !important; }
    .tabs-container { page-break-before: always !important; break-before: page !important; }
    #tab-terminal, .terminal-section { display: none !important; }
    table { font-size: 10px !important; }
    th { color: #555 !important; }
    td { color: #000 !important; }
  }
</style>
</head>
<body>

  <!-- ── Hero Banner ──────────────────────────────────── -->
  <div class="hero">
    <div class="hero-inner">
      <div class="hero-top">
        <div class="hero-brand">
          <span>JDA Connect &bull; P2P Migration Validator</span>
          <span style="background:rgba(255,255,255,0.2);padding:1px 6px;border-radius:3px;font-size:10px;">v8.0</span>
        </div>
        <div class="hero-meta">
          <span><strong>Generated:</strong> $($data.Timestamp)</span>
          <span><strong>Duration:</strong> $($data.Duration)s</span>
          <span><strong>Mode:</strong> Strictly Read-Only</span>
        </div>
      </div>
      <div class="hero-content">
        <div>
          <div class="hero-verdict-text">$($data.Recommendation)</div>
          <div class="hero-sub">&#10003; READ ONLY VALIDATION &bull; NO FILES MODIFIED &bull; NO SERVICES RESTARTED &bull; NO CONFIGURATION CHANGED</div>
        </div>
        <div class="hero-stats">
          <div class="hero-stat">
            <div class="hero-stat-value">$($data.MatchedPairs.Count)/$($data.PrivData.Applications.Count)</div>
            <div class="hero-stat-label">MRTs</div>
          </div>
          <div class="hero-stat">
            <div class="hero-stat-value">$($data.WrapperPassCount)/$($data.MatchedPairs.Count)</div>
            <div class="hero-stat-label">WRAPPER</div>
          </div>
          <div class="hero-stat">
            <div class="hero-stat-value">$appWarningCount Apps</div>
            <div class="hero-stat-label">LOG WARNINGS</div>
          </div>
          <div class="hero-stat">
            <div class="hero-stat-value">$totalDiffs</div>
            <div class="hero-stat-label">DIFFS</div>
          </div>
          <div class="hero-stat">
            <div class="hero-stat-value">$($data.FailCount)</div>
            <div class="hero-stat-label">FAILURES</div>
          </div>
        </div>
      </div>
    </div>
  </div>

  <div class="container">

    <!-- ── Identification Strip ────────────────────────── -->
    <div class="id-strip">
      <div class="id-cell">
        <div class="id-label">Customer</div>
        <div class="id-value">$custDisplay</div>
      </div>
      <div class="id-cell">
        <div class="id-label">INC Number</div>
        <div class="id-value" style="color:var(--text-muted);">$incDisplay</div>
      </div>
      <div class="id-cell">
        <div class="id-label">Reference Server</div>
        <div class="id-value mono">$($data.ReferenceServer)</div>
      </div>
      <div class="id-cell">
        <div class="id-label">Public Server</div>
        <div class="id-value mono">$($data.PublicServer)</div>
      </div>
      <div class="id-cell">
        <div class="id-label">Server Access</div>
        <div class="id-value green">&#10003; Both Reachable</div>
      </div>
    </div>

    <!-- ── Status Heatmap ──────────────────────────────── -->
    <div class="heatmap">
      <div class="heat-cell $mrtHeatClass">
        <div class="heat-icon">&#10003;</div>
        <div class="heat-name">MRT Discovery</div>
        <div class="heat-detail">$mrtHeatText</div>
      </div>
      <div class="heat-cell $svcHeatClass">
        <div class="heat-icon">&#10003;</div>
        <div class="heat-name">Public Services</div>
        <div class="heat-detail">$svcHeatText</div>
      </div>
      <div class="heat-cell $dirHeatClass">
        <div class="heat-icon">&#10003;</div>
        <div class="heat-name">Folders &amp; Temp</div>
        <div class="heat-detail">All Present</div>
      </div>
      <div class="heat-cell $envHeatClass">
        <div class="heat-icon">&#10003;</div>
        <div class="heat-name">Environment</div>
        <div class="heat-detail">Java8 Verified</div>
      </div>
      <div class="heat-cell $wrapHeatClass">
        <div class="heat-icon">&#10003;</div>
        <div class="heat-name">Wrapper Config</div>
        <div class="heat-detail">$wrapHeatText</div>
      </div>
      <div class="heat-cell $critHeatClass">
        <div class="heat-icon">&#10003;</div>
        <div class="heat-name">Escalation Signatures</div>
        <div class="heat-detail">$critHeatText</div>
      </div>
    </div>

    <!-- ── 3-Column Section: Scope | Pre-Cutover Checklist | AMQ ── -->
    <div class="cols-3">
      <div class="section">
        <div class="section-head">Validation Scope</div>
        <div class="section-body">
          <div class="scope-tags">
            <span class="scope-tag"><span class="dot">&#9679;</span> MRT Mapping</span>
            <span class="scope-tag"><span class="dot">&#9679;</span> Services &amp; Accounts</span>
            <span class="scope-tag"><span class="dot">&#9679;</span> Wrapper Configuration</span>
            <span class="scope-tag"><span class="dot">&#9679;</span> Temp Folders</span>
            <span class="scope-tag"><span class="dot">&#9679;</span> ActiveMQ Discovery</span>
            <span class="scope-tag"><span class="dot">&#9679;</span> Environment &amp; Java</span>
            <span class="scope-tag"><span class="dot">&#9679;</span> Escalation Signatures</span>
            <span class="scope-tag"><span class="dot">&#9679;</span> GGSVC MuleDeploy</span>
          </div>
        </div>
      </div>

      <div class="section">
        <div class="section-head">Pre-Cutover Checklist</div>
        <div class="section-body">
          <div class="checklist-grid">
            $actionItemsHtml
          </div>
        </div>
      </div>

      <div class="section">
        <div class="section-head">ActiveMQ Console URLs</div>
        <div class="section-body">
          <div class="amq-grid">
            $amqRowsHtml
          </div>
        </div>
      </div>
    </div>

    <!-- ── Tabbed Detail View ──────────────────────────── -->
    <div class="tabs-container">
      <div class="tabs-nav">
        <button class="tab-btn active" type="button" onclick="showTab('signatures', this)">
          Escalation Signatures <span class="b-count bc-pass">$($m.CriticalList.Count)</span>
        </button>
        <button class="tab-btn" type="button" onclick="showTab('logs', this)">
          Logs <span class="b-count bc-warn">$appWarningCount Apps</span>
        </button>
        <button class="tab-btn" type="button" onclick="showTab('services', this)">
          Services <span class="b-count bc-pass">$($data.PubData.Applications.Count)</span>
        </button>
        <button class="tab-btn" type="button" onclick="showTab('wrapper', this)">
          Wrapper Config <span class="b-count bc-pass">$($data.WrapperPassCount)/$($data.MatchedPairs.Count) PASS</span>
        </button>
        <button class="tab-btn" type="button" onclick="showTab('diffs', this)">
          Differences <span class="b-count bc-pass">$totalDiffs</span>
        </button>
        <button class="tab-btn" type="button" onclick="showTab('terminal', this)">
          Terminal Output
        </button>
      </div>

      <!-- Tab: Signatures -->
      <div id="tab-signatures" class="tab-pane active">
        $(if ($data.TotalCritical -eq 0) {
            "<div class='clean-row'>&#10003; All $($m.CriticalList.Count) Escalation Signatures Clean: 0 occurrences detected across all scanned logs.</div>"
        } else { "" })
        <table style="margin-top:14px;">
          <thead><tr><th>Pattern</th><th>Occurrences</th><th>Severity</th><th>Status</th></tr></thead>
          <tbody>
            $critRows
          </tbody>
        </table>
      </div>

      <!-- Tab: Logs -->
      <div id="tab-logs" class="tab-pane">
        <table>
          <thead><tr><th>Application</th><th>Active Log File</th><th>Errors</th><th>Fatals</th><th>Exceptions</th><th>Visual Breakdown</th><th>Status</th></tr></thead>
          <tbody>
            $logRows
          </tbody>
        </table>
        <div style="display:flex;gap:18px;margin-top:14px;padding-top:12px;border-top:1px solid var(--border-color);font-size:10.5px;color:var(--text-secondary);font-weight:700;">
          <span><span class="es-err" style="display:inline-block;width:10px;height:10px;border-radius:2px;vertical-align:middle;"></span> Errors</span>
          <span><span class="es-fat" style="display:inline-block;width:10px;height:10px;border-radius:2px;vertical-align:middle;"></span> Fatals</span>
          <span><span class="es-exc" style="display:inline-block;width:10px;height:10px;border-radius:2px;vertical-align:middle;"></span> Exceptions</span>
        </div>
      </div>

      <!-- Tab: Services -->
      <div id="tab-services" class="tab-pane">
        <table>
          <thead><tr><th>Service Name</th><th>State</th><th>Start Mode</th><th>Logon Account</th><th>Status</th></tr></thead>
          <tbody>
            $svcRows
          </tbody>
        </table>
      </div>

      <!-- Tab: Wrapper Config -->
      <div id="tab-wrapper" class="tab-pane">
        $wrapCardsHtml
      </div>

      <!-- Tab: Differences -->
      <div id="tab-diffs" class="tab-pane">
        <div class="clean-row">&#10003; No Differences Detected &bull; Only On Reference: None &nbsp;|&nbsp; Only On Public: None &nbsp;|&nbsp; Missing On Public: None</div>
      </div>

      <!-- Tab: Terminal Output -->
      <div id="tab-terminal" class="tab-pane">
        <div class="ps-terminal-window">
          <div class="ps-terminal-header">
            <div class="ps-tab">
              <span class="ps-tab-prompt">PS</span>
              <span>$($data.PublicServer) &gt; p2p-validation-v80.log</span>
            </div>
            <div class="ps-actions">
              <button class="ps-btn" type="button" onclick="window.print()">Print / PDF</button>
              <button class="ps-btn" type="button" onclick="copyPSTerminalText()">Copy Terminal Output</button>
            </div>
          </div>
          <div class="ps-terminal-body">
            <pre class="ps-code" id="psTerminalOutput">$safeFullText</pre>
          </div>
        </div>
      </div>
    </div>

    <div class="footer">
      P2P Migration Validator v8.0 &bull; JDA Connect Migration Automation &bull; Strictly Read-Only
    </div>

  </div><!-- .container -->

<script>
function showTab(name, btn) {
  document.querySelectorAll('.tab-pane').forEach(function(p) { p.classList.remove('active'); });
  document.querySelectorAll('.tab-btn').forEach(function(b) { b.classList.remove('active'); });
  document.getElementById('tab-' + name).classList.add('active');
  btn.classList.add('active');
}

function copyPSTerminalText() {
  var el = document.getElementById('psTerminalOutput');
  var text = el.innerText || el.textContent;
  navigator.clipboard.writeText(text).then(function() {
    alert('Full terminal report copied to clipboard!');
  }).catch(function() {
    var range = document.createRange();
    range.selectNode(el);
    window.getSelection().removeAllRanges();
    window.getSelection().addRange(range);
    document.execCommand('copy');
    alert('Full terminal report copied to clipboard!');
  });
}
</script>
</body>
</html>
"@

        $htmlContent | Set-Content -Path $file -Encoding UTF8 -ErrorAction Stop
        $statusText.Text = "Executive HTML Dashboard Saved & Opened!"
        Start-Process $file
    } catch {
        [System.Windows.Forms.MessageBox]::Show("HTML Export Failed:`n$($_.Exception.Message)", "Error") | Out-Null
    }
})

# ==========================================================
# SHOW FORM
# ==========================================================

[void]$form.ShowDialog()
