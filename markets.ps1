# Out-of-town local stations: one small file per station, so the TV fetches
# only the rows it shows. Separate from fetch.ps1 so a block here cannot
# break the Boston guide. Output: out/st/<CALL>.json and out/index.json.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
if ($PSVersionTable.PSVersion.Major -lt 6) { Remove-TypeData System.Array -ErrorAction SilentlyContinue }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $here 'out'
$stDir = Join-Path $outDir 'st'
New-Item -ItemType Directory -Force $stDir | Out-Null

$want = @{}
Get-Content (Join-Path $here 'stations.txt') | ForEach-Object {
    $c = $_.Trim().ToUpper()
    if ($c -and -not $c.StartsWith('#')) { $want[$c] = 1 }
}
$zips = @(Get-Content (Join-Path $here 'markets.txt') | Where-Object { $_ -match '^\d{5}' } | ForEach-Object { $_.Substring(0, 5) })

function Base($cs) { return [regex]::Match($cs.ToUpper(), '^(.+?)(DT|HD|SD|CD|LD)?$').Groups[1].Value }
function UnixOf($iso) {
    $d = [DateTime]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    return [int64]($d - [DateTime]'1970-01-01').TotalSeconds
}

$now = [int64]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
$from = $now - ($now % 3600) - 3 * 3600   # 3 hours back
$steps = 5                                # 5 x 6 hours = 30 hours
$out = @{}; $owner = @{}; $calls = 0; $fails = 0

foreach ($z in $zips) {
    for ($i = 0; $i -lt $steps; $i++) {
        $t = $from + $i * 21600
        $url = "https://tvlistings.gracenote.com/api/grid?lineupId=USA-lineupId-DEFAULT&timespan=6&headendId=lineupId&country=USA&timezone=&device=-&postalCode=$z&isOverride=true&time=$t&pref=16%2C128&userId=-&aid=orbebb&languagecode=en-us"
        $calls++
        try { $grid = Invoke-RestMethod $url -TimeoutSec 60 }
        catch { $fails++; Write-Host "skip $z $t : $($_.Exception.Message)"; continue }
        $new = 0
        foreach ($c in $grid.channels) {
            $b = Base $c.callSign
            if (-not $want[$b]) { continue }
            if ($owner[$b] -and $owner[$b] -ne $z) { continue }
            if (-not $owner[$b]) { $owner[$b] = $z; $out[$b] = @{} }
            $new++
            foreach ($e in $c.events) {
                $s = UnixOf $e.startTime
                if ($out[$b][$s]) { continue }
                $p = $e.program
                $desc = "$($p.shortDesc)"
                if ($desc.Length -gt 160) { $desc = $desc.Substring(0, 160) }
                $out[$b][$s] = @($s, (UnixOf $e.endTime), "$($p.title)", "$($p.episodeTitle)", $desc)
            }
        }
        Start-Sleep -Milliseconds 400   # be gentle
        if ($new -eq 0) { break }       # this market adds no stations: skip its other windows
    }
    if ($fails -gt 40) { throw "Too many failed requests; Gracenote may be blocking. Stopping." }
}

$enc = New-Object Text.UTF8Encoding $false
foreach ($k in $out.Keys) {
    $rows = @($out[$k].Keys | Sort-Object | ForEach-Object { , $out[$k][$_] })
    [IO.File]::WriteAllText((Join-Path $stDir "$k.json"), (ConvertTo-Json $rows -Depth 4 -Compress), $enc)
}
$index = [ordered]@{ made = $now; st = @($out.Keys | Sort-Object) }
[IO.File]::WriteAllText((Join-Path $outDir 'index.json'), (ConvertTo-Json $index -Compress), $enc)
Write-Host ("{0} stations of {1} wanted, {2} requests, {3} failed" -f $out.Count, $want.Count, $calls, $fails)
