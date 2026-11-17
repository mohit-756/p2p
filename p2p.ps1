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
                $region = if ($v1Norm -match '//([^\.]+)\.') { $matches[1] } else { "Valid" }
                $dispV1 = "Configured ($region)"
                $dispV2 = "Configured ($region)"
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
            "http://$NewServer`:11080/index.html",
            "http://$NewServer`:31080/index.html",
            "http://$NewServer`:51080/index.html"
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
        if ($pAmq -and $nAmq) {
            $Report.Add(("ActiveMQ     : Present on Reference and Public ({0})  [PASS]" -f ($PubData.AmqFolders -join ', ')))
        } elseif (-not $pAmq -and -not $nAmq) {
            $Report.Add("ActiveMQ     : Not Present on Reference Server - Not Required  [PASS]")
        } elseif ($pAmq -and -not $nAmq) {
            $Report.Add("ActiveMQ     : Present on Reference But Missing on Public  [FAIL]")
            $RiskItems += "ActiveMQ present on Reference server but missing on Public"
            $OnlyOnReference += "ActiveMQ"
            $ReferenceRequiredMissing += "ActiveMQ"
            $amqOk = $false
        } else {
            $Report.Add(("ActiveMQ     : Present Only on Public ({0})  [INFO]" -f ($PubData.AmqFolders -join ', ')))
            $OnlyOnPublic += "ActiveMQ"
        }

        # AMQ Listener Ports, Status & Console URLs
        if ($PubData.AmqFolders.Count -gt 0) {
            if ($PubData.AmqListeningPorts.Count -gt 0) {
                $Report.Add("")
                $Report.Add(
                    ("AMQ Listener Ports : {0}" -f ($PubData.AmqListeningPorts -join ", "))
                )
                $Report.Add(
                    "AMQ Status         : LISTENING [PASS]"
                )
            }

            $Report.Add("")
            $Report.Add("AMQ Console URLs :")
            foreach ($u in $AmqUrls) {
                $Report.Add("  $u")
            }
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

        # 7. CRITICAL ERROR ANALYSIS
        Add-ReportSection -Report $Report -Title "7. CRITICAL ERROR ANALYSIS"
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
        $Report.Add("Wrapper Custom Properties Checked : 4 (Oracle JDBC, Gatekeeper, Base URI, JavaTmpDir)")
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
        $Report.Add(("{0,-26} : {1}" -f "Critical Log Signatures", $(if ($totalCritical -eq 0) { "PASS" } else { "WARNING" })))
        
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
        $Report.Add(("  {0} Critical Log Signatures ({1} Detected)" -f $(if ($totalCritical -eq 0) { "[OK]" } else { "[WARNING]" }), $totalCritical))
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
        foreach ($c in $critFound) {
            $loc = if ($c.LogFile) { " (Found In: $($c.LogFile))" } else { "" }
            $actionItems += "Review <strong>$($c.Pattern)</strong> occurrences$loc"
        }
        if (-not $data.WrapperOk) {
            $actionItems += "Review wrapper.conf property discrepancies flagged in Section 5"
        } else {
            $actionItems += "<span style='color:#34d399;'>&check; No Wrapper Issues Detected</span>"
        }
        $totalDiffs = $data.OnlyOnReference.Count + $data.OnlyOnPublic.Count
        if ($totalDiffs -gt 0 -and $data.ReferenceRequiredMissing.Count -gt 0) {
            $actionItems += "Resolve missing reference components on Public: $($data.ReferenceRequiredMissing -join ', ')"
        } else {
            $actionItems += "<span style='color:#34d399;'>&check; No Reference Differences Detected</span>"
        }

        # ActiveMQ Environment Badges in Action Box
        if ($data.PubData.AmqFolders.Count -gt 0) {
            $listeningSet = @($data.PubData.AmqListeningPorts)
            $pillList = @()
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
                    $pillList += "<a href='$u' target='_blank' class='amq-pill active-listener'><span class='env-tag'>$envLabel ($port)</span> <span class='live-badge'>&#9679; LISTENING</span> <span class='pill-url'>$u</span></a>"
                } else {
                    $pillList += "<a href='$u' target='_blank' class='amq-pill'><span class='env-tag'>$envLabel ($port)</span> <span class='pill-url'>$u</span></a>"
                }
            }
            $actionItems += "<div><strong>ActiveMQ Console URLs (Manual Browser Verification):</strong></div><div class='amq-pill-container'>" + ($pillList -join "") + "</div>"
        }

        $actionHtml = "<ul class='action-list'>"
        foreach ($item in $actionItems) { $actionHtml += "<li>$item</li>" }
        $actionHtml += "</ul>"

        # Services Rows
        $svcRows = ""
        foreach ($s in $data.PubData.Applications) {
            $mode = if ($s.StartMode -eq "Auto" -and $s.DelayedAutoStart) { "Delayed Auto" } else { $s.StartMode }
            $ok = ($s.State -eq "Running" -and $mode -match "Auto" -and -not [string]::IsNullOrWhiteSpace($s.StartName))
            $st = if ($ok) { '<span class="badge pass">PASS</span>' } else { '<span class="badge fail">FAIL</span>' }
            $svcRows += "<tr><td>$($s.ServiceName)</td><td>$($s.State)</td><td>$mode</td><td>$($s.StartName)</td><td>$st</td></tr>"
        }

        # Critical Rows
        $critRows = ""
        foreach ($ci in $m.CriticalList) {
            $st = if ($ci.Count -gt 0) { '<span class="badge warn">WARNING</span>' } else { '<span class="badge pass">PASS</span>' }
            $fileLabel = if ($ci.Count -gt 0 -and $ci.LogFile) { "<span class='log-file'>$($ci.LogFile)</span>" } else { "" }
            $samp = if ($ci.Count -gt 0 -and $ci.Sample) { "<br><span class='code-sample'>Sample: $([System.Net.WebUtility]::HtmlEncode($ci.Sample))</span>" } else { "" }
            $critRows += "<tr><td><strong>$($ci.Pattern)</strong></td><td>$($ci.Count)</td><td>$st $fileLabel $samp</td></tr>"
        }

        # Actionable Log Rows
        $logRows = ""
        if ($data.ActionableLogs.Count -gt 0) {
            foreach ($lr in $data.ActionableLogs) {
                $logRows += "<tr><td>$($lr.AppFolder)</td><td>$($lr.LogName)</td><td>$($lr.Errors)</td><td>$($lr.Fatals)</td><td>$($lr.Exceptions)</td><td><span class='badge warn'>WARNING</span></td></tr>"
            }
        } else {
            $logRows = "<tr><td colspan='6' style='text-align:center;color:#34d399;'>All scanned application logs are clean (0 Errors, 0 Fatals, 0 Exceptions)</td></tr>"
        }

        $diffValColor = if ($totalDiffs -eq 0) { "#34d399" } else { "#fbbf24" }

        # SERVER ACCESS Tile
        $serverAccessTileHtml = @"
            <div class="metric-card">
                <div class="metric-label">SERVER ACCESS</div>
                <div class="metric-value" style="font-size:13px;color:#34d399;font-weight:700;line-height:1.4;">
                    REF: Reachable<br>PUB: Reachable
                </div>
            </div>
"@

        # ACTIVE MQ Installed Tile with Ports (Cleaner: showing status & port)
        $amqInstalled = ($data.PubData.AmqFolders.Count -gt 0)
        $amqStatusText  = if ($amqInstalled) { "INSTALLED" } else { "NOT INSTALLED" }
        $amqStatusColor = if ($amqInstalled) { "#34d399" } else { "#9ca3af" }
        $amqPorts = if ($data.PubData.AmqListeningPorts.Count -gt 0) {
            $data.PubData.AmqListeningPorts -join ","
        } else {
            "N/A"
        }

        $amqTileHtml = @"
            <div class="metric-card">
                <div class="metric-label">ACTIVE MQ</div>
                <div class="metric-value" style="color:$amqStatusColor;">
                    $amqStatusText
                </div>
                <div style="font-size:12px;color:#93c5fd;font-weight:700;margin-top:4px;font-family:Consolas,monospace;">
                    $amqPorts
                </div>
            </div>
"@

        # WRAPPER Summary Tile (e.g., 6/6 PASS | 4 Custom Props)
        $wrapPassTotal   = "$($data.WrapperPassCount)/$($data.MatchedPairs.Count) PASS"
        $wrapStatColor   = if ($data.WrapperOk -and $data.MatchedPairs.Count -gt 0) { "#34d399" } else { "#f87171" }
        $wrapperTileHtml = @"
            <div class="metric-card">
                <div class="metric-label">WRAPPER (4 PROPS)</div>
                <div class="metric-value" style="color:$wrapStatColor;">$wrapPassTotal</div>
            </div>
"@

        # Customer / INC Display Fix (ikea () -> ikea)
        $custIncHtml = if ([string]::IsNullOrWhiteSpace($data.INC)) {
            [System.Net.WebUtility]::HtmlEncode($data.Customer)
        } else {
            "$([System.Net.WebUtility]::HtmlEncode($data.Customer)) <span style=""font-size:12px;color:#9ca3af;"">($([System.Net.WebUtility]::HtmlEncode($data.INC)))</span>"
        }

        # Auto-collapse: Open accordions only if issues exist
        $critAccordionOpen = if ($data.TotalCritical -gt 0) { "open" } else { "" }
        $logAccordionOpen  = if ($data.ActionableLogs.Count -gt 0) { "open" } else { "" }
        $diffAccordionOpen = if ($totalDiffs -gt 0) { "open" } else { "" }

        $safeFullText = [System.Net.WebUtility]::HtmlEncode($data.FullReportText)
        $safeFullText = $safeFullText -replace '\[PASS\]', '<span class="badge pass">PASS</span>'
        $safeFullText = $safeFullText -replace '\[FAIL\]', '<span class="badge fail">FAIL</span>'
        $safeFullText = $safeFullText -replace '\[WARNING\]', '<span class="badge warn">WARN</span>'
        $safeFullText = $safeFullText -replace '\[INFO\]', '<span class="badge info">INFO</span>'
        $safeFullText = $safeFullText -replace '\[OK\]', '<span class="badge pass">OK</span>'

        $htmlContent = @"
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>P2P Migration Decision Dashboard - $($data.Customer)</title>
    <style>
        body { background-color: #111827; color: #e2e8f0; font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, Roboto, sans-serif; margin: 0; padding: 25px; }
        .container { max-width: 1120px; margin: 0 auto; }
        
        .dashboard-header {
            position: relative;
            background: #1e293b;
            border: 1px solid #374151;
            border-radius: 10px;
            padding: 22px 28px;
            box-shadow: 0 2px 6px rgba(0,0,0,0.15);
            margin-bottom: 20px;
        }
        .header-top { display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #374151; padding-bottom: 14px; margin-bottom: 18px; }
        .logo-title { font-size: 19px; font-weight: 800; color: #e5e7eb; letter-spacing: 0.5px; }
        .timestamp { font-size: 12px; color: #9ca3af; }
        
        .metrics-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 18px; }
        @media (max-width: 900px) { .metrics-grid { grid-template-columns: repeat(2, 1fr); } }
        .metric-card { background: #1f2937; border: 1px solid #374151; border-radius: 8px; padding: 14px 18px; box-shadow: 0 2px 6px rgba(0,0,0,0.15); }
        .metric-label { font-size: 11px; text-transform: uppercase; color: #9ca3af; font-weight: 700; margin-bottom: 5px; letter-spacing: 0.5px; }
        .metric-value { font-size: 20px; font-weight: 700; color: #ffffff; }
        .val-risk { font-size: 24px; font-weight: 800; color: $riskColor; }
        .val-diff { color: $diffValColor; font-weight: 800; }

        .decision-banner { padding: 16px 22px; border-radius: 8px; display: flex; justify-content: space-between; align-items: center; }
        .badge-ok { background: #064e3b; border: 1px solid #059669; color: #34d399; }
        .badge-warn { background: #78350f; border: 1px solid #d97706; color: #fde68a; }
        .badge-fail { background: #7f1d1d; border: 1px solid #dc2626; color: #fecaca; }
        .decision-title { font-size: 11.5px; text-transform: uppercase; font-weight: 800; letter-spacing: 0.5px; opacity: 0.9; }
        .decision-text { font-size: 26px; font-weight: 800; letter-spacing: 0.5px; }
        .decision-subtitle { font-size: 11px; font-weight: 700; letter-spacing: 0.8px; text-transform: uppercase; margin-top: 6px; opacity: 0.95; }

        .scope-card { background: #1f2937; border: 1px solid #374151; border-radius: 8px; padding: 16px 20px; margin-bottom: 20px; box-shadow: 0 2px 6px rgba(0,0,0,0.15); }
        .scope-title { font-size: 12px; text-transform: uppercase; font-weight: 800; color: #e5e7eb; letter-spacing: 0.5px; margin-bottom: 10px; }
        .scope-list { margin: 0; padding: 0; list-style: none; color: #d1d5db; font-size: 13px; display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 8px; }
        .scope-list li { display: flex; align-items: center; gap: 8px; }
        .scope-check { color: #34d399; font-weight: 800; font-size: 14px; }

        .action-box { background: #1e1b4b; border-left: 4px solid #6366f1; border-radius: 8px; padding: 16px 22px; margin-bottom: 20px; box-shadow: 0 2px 6px rgba(0,0,0,0.15); }
        .action-title { font-size: 13px; font-weight: 800; color: #a5b4fc; text-transform: uppercase; margin-bottom: 8px; }
        .action-list { margin: 0; padding-left: 20px; color: #e0e7ff; line-height: 1.6; font-size: 13px; }

        .amq-pill-container { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; margin-bottom: 4px; }
        .amq-pill { display: inline-flex; align-items: center; gap: 8px; background: #111827; border: 1px solid #374151; padding: 7px 14px; border-radius: 6px; color: #93c5fd; text-decoration: none; font-size: 12px; font-family: Consolas, monospace; transition: all 0.15s ease-in-out; }
        .amq-pill:hover { background: #1f2937; border-color: #60a5fa; color: #ffffff; }
        .amq-pill.active-listener { background: #064e3b; border-color: #10b981; color: #ecfdf5; box-shadow: 0 0 10px rgba(16, 185, 129, 0.25); }
        .amq-pill.active-listener:hover { background: #047857; color: #ffffff; }
        .amq-pill .env-tag { font-weight: 800; font-family: 'Segoe UI', sans-serif; letter-spacing: 0.5px; }
        .amq-pill .live-badge { background: #10b981; color: #022c22; font-size: 10px; font-weight: 800; padding: 1px 6px; border-radius: 4px; letter-spacing: 0.5px; font-family: 'Segoe UI', sans-serif; }
        .amq-pill .pill-url { color: #d1d5db; font-size: 11px; }
        .amq-pill.active-listener .pill-url { color: #a7f3d0; }

        .matrix-card { background: #1f2937; border: 1px solid #374151; border-radius: 8px; padding: 18px 22px; margin-bottom: 20px; box-shadow: 0 2px 6px rgba(0,0,0,0.15); }
        .matrix-title { font-size: 13.5px; font-weight: 800; color: #e5e7eb; text-transform: uppercase; margin-bottom: 14px; letter-spacing: 0.5px; }
        .matrix-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; }
        @media (max-width: 768px) { .matrix-grid { grid-template-columns: repeat(2, 1fr); } }
        .matrix-item { background: #111827; border: 1px solid #374151; border-radius: 6px; padding: 16px; min-height: 55px; display: flex; justify-content: space-between; align-items: center; font-size: 14px; font-weight: 600; }

        details { background: #1f2937; border: 1px solid #374151; border-radius: 8px; margin-bottom: 14px; overflow: hidden; box-shadow: 0 2px 6px rgba(0,0,0,0.15); }
        summary { padding: 13px 18px; font-weight: 700; font-size: 13px; cursor: pointer; background: #1f2937; color: #d1d5db; user-select: none; }
        summary:hover { background: #283548; color: #ffffff; }
        .section-content { padding: 16px 20px; border-top: 1px solid #374151; background: #111827; }
        
        table { width: 100%; border-collapse: collapse; font-size: 12.5px; margin: 4px 0; }
        th { text-align: left; padding: 10px 12px; background: #1f2937; color: #9ca3af; font-size: 11px; text-transform: uppercase; font-weight: 700; border-bottom: 1px solid #374151; }
        td { padding: 9px 12px; border-bottom: 1px solid #1f2937; color: #f3f4f6; }
        tr:hover td { background: #1e293b; }
        
        .badge { padding: 3px 8px; border-radius: 4px; font-weight: 800; font-size: 11px; display: inline-block; min-width: 65px; text-align: center; }
        .pass { background: #065f46; color: #34d399; }
        .fail { background: #7f1d1d; color: #f87171; }
        .warn { background: #78350f; color: #fbbf24; }
        .info { background: #1e3a8a; color: #93c5fd; }
        
        .log-file { font-family: Consolas, monospace; font-size: 11px; color: #93c5fd; background: #1e3a8a; padding: 2px 6px; border-radius: 4px; display: inline-block; margin-left: 8px; }
        .code-sample { font-family: Consolas, monospace; font-size: 11px; color: #fca5a5; background: #450a0a; padding: 4px 8px; border-radius: 4px; display: inline-block; margin-top: 4px; }
        pre { font-family: Consolas, 'Courier New', monospace; font-size: 12.5px; line-height: 1.5; color: #f9fafb; overflow-x: auto; margin: 0; }

        .clean-banner { display: flex; align-items: center; gap: 10px; padding: 10px 14px; background: #064e3b; border: 1px solid #059669; border-radius: 6px; margin-bottom: 12px; color: #ecfdf5; font-size: 13px; font-weight: 600; }

        /* Print-to-PDF Friendly CSS (Strict 2-Page Executive Brief) */
        @media print {
            @page {
                size: A4 portrait;
                margin: 10mm 12mm;
            }
            body {
                background: #ffffff !important;
                color: #000000 !important;
                padding: 0 !important;
                margin: 0 !important;
                font-size: 11px !important;
            }
            .container { max-width: 100% !important; margin: 0 !important; }
            .dashboard-header, .metric-card, .scope-card, .action-box, .matrix-card, details, .section-content {
                background: #ffffff !important;
                color: #000000 !important;
                border: 1px solid #d1d5db !important;
                box-shadow: none !important;
                page-break-inside: avoid !important;
                break-inside: avoid !important;
            }
            .dashboard-header { padding: 12px 18px !important; margin-bottom: 10px !important; }
            .header-top { padding-bottom: 8px !important; margin-bottom: 10px !important; }
            .logo-title { font-size: 16px !important; color: #111827 !important; }
            .timestamp { color: #4b5563 !important; }
            
            .metrics-grid { gap: 8px !important; margin-bottom: 10px !important; }
            .metric-card { padding: 8px 12px !important; }
            .metric-label { color: #4b5563 !important; font-size: 10px !important; margin-bottom: 3px !important; }
            .metric-value { font-size: 16px !important; color: #111827 !important; }
            
            .decision-banner { padding: 10px 14px !important; }
            .decision-title { font-size: 10.5px !important; }
            .decision-text { font-size: 20px !important; }
            .decision-subtitle { font-size: 10px !important; }
            
            .scope-card { padding: 10px 14px !important; margin-bottom: 10px !important; }
            .scope-title { color: #111827 !important; margin-bottom: 6px !important; }
            .scope-list { line-height: 1.5 !important; font-size: 11.5px !important; gap: 4px !important; color: #374151 !important; }
            
            .action-box {
                background: #f8fafc !important;
                border: 1px solid #cbd5e1 !important;
                border-left: 4px solid #4f46e5 !important;
                padding: 10px 14px !important;
                margin-bottom: 10px !important;
                page-break-inside: avoid !important;
                break-inside: avoid !important;
            }
            .action-title { color: #312e81 !important; margin-bottom: 4px !important; }
            .action-list { color: #1e293b !important; }
            
            .amq-pill {
                background: #f1f5f9 !important;
                border: 1px solid #cbd5e1 !important;
                color: #1e40af !important;
                padding: 4px 8px !important;
                font-size: 10.5px !important;
            }
            .amq-pill.active-listener {
                background: #ecfdf5 !important;
                border-color: #059669 !important;
                color: #065f46 !important;
            }
            .amq-pill .pill-url { color: #475569 !important; }
            .amq-pill.active-listener .pill-url { color: #047857 !important; }
            
            .matrix-card {
                padding: 12px 14px !important;
                margin-bottom: 0 !important;
                page-break-inside: avoid !important;
                break-inside: avoid !important;
                page-break-after: always !important;
                break-after: page !important;
            }
            .matrix-title { color: #111827 !important; margin-bottom: 8px !important; }
            .matrix-grid { gap: 8px !important; }
            .matrix-item {
                background: #f9fafb !important;
                border: 1px solid #e5e7eb !important;
                padding: 8px 12px !important;
                min-height: 36px !important;
                color: #111827 !important;
                font-size: 12px !important;
            }

            details {
                margin-bottom: 10px !important;
                page-break-inside: avoid !important;
                break-inside: avoid !important;
            }
            summary {
                color: #111827 !important;
                background: #f3f4f6 !important;
                border-bottom: 1px solid #e5e7eb !important;
                padding: 8px 12px !important;
                font-size: 12px !important;
            }
            .section-content {
                background: #ffffff !important;
                border-top: 1px solid #e5e7eb !important;
                padding: 10px 12px !important;
                display: block !important;
            }
            
            table { font-size: 11px !important; }
            th { background: #f3f4f6 !important; color: #374151 !important; padding: 6px 8px !important; }
            td { color: #111827 !important; padding: 6px 8px !important; border-bottom: 1px solid #f3f4f6 !important; }
            tr:hover td { background: transparent !important; }

            .badge.pass { background: #d1fae5 !important; color: #065f46 !important; }
            .badge.warn { background: #fef3c7 !important; color: #92400e !important; }
            .badge.fail { background: #fee2e2 !important; color: #991b1b !important; }
            .clean-banner { background: #d1fae5 !important; border: 1px solid #059669 !important; color: #065f46 !important; }

            /* Strictly hide the 6-page plain-text dump in print so PDF is a 2-page brief */
            .terminal-details {
                display: none !important;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <!-- TOP EXECUTIVE DECISION CARD -->
        <div class="dashboard-header">
            <div class="header-top">
                <div class="logo-title">P2P MIGRATION CUTOVER DECISION</div>
                <div class="timestamp">Generated: $($data.Timestamp) | Validation Duration: $($data.Duration)s</div>
            </div>

            <div class="metrics-grid">
                <div class="metric-card">
                    <div class="metric-label">CUSTOMER / INC</div>
                    <div class="metric-value">$custIncHtml</div>
                </div>
                <div class="metric-card">
                    <div class="metric-label">SERVERS (REF &rarr; PUB)</div>
                    <div class="metric-value" style="font-size:13px;word-break:break-all;">$($data.ReferenceServer)<br>&rarr; $($data.PublicServer)</div>
                </div>
                $serverAccessTileHtml
                <div class="metric-card">
                    <div class="metric-label">MRT MATCH</div>
                    <div class="metric-value">$($data.MatchedPairs.Count) / $($data.PrivData.Applications.Count)</div>
                </div>
                $wrapperTileHtml
                $amqTileHtml
                <div class="metric-card">
                    <div class="metric-label">DIFFERENCES</div>
                    <div class="metric-value val-diff">$totalDiffs</div>
                </div>
                <div class="metric-card">
                    <div class="metric-label">RISK LEVEL</div>
                    <div class="metric-value val-risk">$($data.RiskLevel)</div>
                </div>
            </div>

            <div class="decision-banner $recClass">
                <div>
                    <div class="decision-title">Recommended Cutover Decision</div>
                    <div class="decision-text">$($data.Recommendation)</div>
                    <div class="decision-subtitle">
                        READ ONLY VALIDATION &bull; NO FILES MODIFIED &bull; NO SERVICES RESTARTED
                    </div>
                </div>
                <div style="font-weight:700;font-size:13px;text-align:right;">$($data.FailCount) Failures Detected</div>
            </div>
        </div>

        <!-- VALIDATION SCOPE CARD -->
        <div class="scope-card">
            <div class="scope-title">Validation Scope</div>
            <ul class="scope-list">
                <li><span class="scope-check">&#10003;</span> MRT Mapping</li>
                <li><span class="scope-check">&#10003;</span> Services &amp; Accounts</li>
                <li><span class="scope-check">&#10003;</span> Wrapper Configuration</li>
                <li><span class="scope-check">&#10003;</span> Temp Folders</li>
                <li><span class="scope-check">&#10003;</span> ActiveMQ Discovery</li>
                <li><span class="scope-check">&#10003;</span> Environment &amp; Java</li>
                <li><span class="scope-check">&#10003;</span> Log Escalation Signatures</li>
            </ul>
        </div>

        <!-- ACTION REQUIRED BOX -->
        <div class="action-box">
            <div class="action-title">Action Required Before Sign-off</div>
            $actionHtml
        </div>

        <!-- CUTOVER DECISION MATRIX -->
        <div class="matrix-card">
            <div class="matrix-title">Cutover Decision Matrix</div>
            <div class="matrix-grid">
                <div class="matrix-item"><span>MRT Discovery</span> $(if ($data.MappingOk) { '<span class="badge pass">PASS</span>' } else { '<span class="badge fail">FAIL</span>' })</div>
                <div class="matrix-item"><span>Public Services</span> $(if ($data.SvcOk) { '<span class="badge pass">PASS</span>' } else { '<span class="badge fail">FAIL</span>' })</div>
                <div class="matrix-item"><span>Folders &amp; Temp</span> $(if ($data.FolderOk) { '<span class="badge pass">PASS</span>' } else { '<span class="badge fail">FAIL</span>' })</div>
                <div class="matrix-item"><span>Environment &amp; Java</span> $(if ($data.EnvOk) { '<span class="badge pass">PASS</span>' } else { '<span class="badge warn">WARN</span>' })</div>
                <div class="matrix-item"><span>Wrapper Configuration</span> $(if ($data.WrapperOk) { '<span class="badge pass">PASS</span>' } else { '<span class="badge fail">FAIL</span>' })</div>
                <div class="matrix-item"><span>Critical Signatures</span> $(if ($data.TotalCritical -eq 0) { '<span class="badge pass">PASS</span>' } else { '<span class="badge warn">WARN</span>' })</div>
            </div>
        </div>

        <!-- ACCORDIONS (SMART COLLAPSE: EXPANDED ONLY IF ISSUES FOUND) -->
        <details $critAccordionOpen>
            <summary>&bull; Critical Error Analysis (With Log File & Live Samples)</summary>
            <div class="section-content">
                $(if ($data.TotalCritical -eq 0) {
                    "<div class='clean-banner'><span class='badge pass'>PASS</span> <strong>All 9 Critical Escalation Signatures Clean:</strong> 0 occurrences detected across all scanned logs.</div>"
                } else { "" })
                <table>
                    <thead>
                        <tr><th style="width:230px;">Pattern</th><th style="width:90px;">Occurrences</th><th>Findings, Location & Sample Line</th></tr>
                    </thead>
                    <tbody>
                        $critRows
                    </tbody>
                </table>
            </div>
        </details>

        <details $logAccordionOpen>
            <summary>&bull; Actionable Log Findings</summary>
            <div class="section-content">
                <table>
                    <thead>
                        <tr><th>Application</th><th>Log File</th><th>Errors</th><th>Fatals</th><th>Exceptions</th><th>Status</th></tr>
                    </thead>
                    <tbody>
                        $logRows
                    </tbody>
                </table>
            </div>
        </details>

        <details>
            <summary>&bull; Public Server Services & Accounts</summary>
            <div class="section-content">
                <table>
                    <thead>
                        <tr><th>Service Name</th><th>State</th><th>Start Mode</th><th>Logon Account</th><th>Status</th></tr>
                    </thead>
                    <tbody>
                        $svcRows
                    </tbody>
                </table>
            </div>
        </details>

        <details $diffAccordionOpen>
            <summary>&bull; Reference Differences & Mismatches</summary>
            <div class="section-content">
                <p><strong>Only On Reference:</strong> $(if ($data.OnlyOnReference.Count -gt 0) { $data.OnlyOnReference -join ', ' } else { 'None' })</p>
                <p><strong>Only On Public:</strong> $(if ($data.OnlyOnPublic.Count -gt 0) { $data.OnlyOnPublic -join ', ' } else { 'None' })</p>
                <p><strong>Required Missing On Public:</strong> $(if ($data.ReferenceRequiredMissing.Count -gt 0) { "<span class='badge fail'>" + ($data.ReferenceRequiredMissing -join ', ') + "</span>" } else { '<span class="badge pass">None</span>' })</p>
            </div>
        </details>

        <details class="terminal-details">
            <summary>&bull; Complete Plain-Text Terminal Report (For INC Attachment)</summary>
            <div class="section-content">
                <pre>$safeFullText</pre>
            </div>
        </details>
    </div>
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
