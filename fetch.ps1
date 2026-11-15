# Builds guide.json from Gracenote's public TV listings grid.
# Runs on GitHub (pwsh 7) or on the PC (Windows PowerShell 5.1).
# Output: { "made": unix, "ch": { "WCVB": [[start, end, "title", "episode", "desc"], ...] } }
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
# PowerShell 5.1 otherwise writes arrays as {"value":[...],"Count":n}.
if ($PSVersionTable.PSVersion.Major -lt 6) { Remove-TypeData System.Array -ErrorAction SilentlyContinue }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# lineupId, headendId, device, zip
$lineups = @(
    @('USA-lineupId-DEFAULT', 'lineupId', '-', '02108'),  # Boston antenna
    @('USA-lineupId-DEFAULT', 'lineupId', '-', '03824'),  # New Hampshire antenna (WENH, WMUR)
    @('USA-MA20483-DEFAULT', 'MA20483', 'X', '02108')     # Xfinity Boston (NESN, NBC Sports Boston)
)

$want = @{}
Get-Content (Join-Path $here 'channels.txt') | ForEach-Object {
    $c = $_.Trim().ToUpper()
    if ($c -and -not $c.StartsWith('#')) { $want[$c] = 1 }
}

# Main-channel variants only: WCVB, WCVBDT, WCVBHD... (not WCVBDT2).
function Base($cs) {
    $m = [regex]::Match($cs.ToUpper(), '^(.+?)(DT|HD|SD|CD|LD)?$')
    return $m.Groups[1].Value
}
function UnixOf($iso) {
    $d = [DateTime]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    return [int64]($d - [DateTime]'1970-01-01').TotalSeconds
}

$now = [int64]([DateTime]::UtcNow - [DateTime]'1970-01-01').TotalSeconds
$from = $now - ($now % 10800) - 6 * 3600    # 6 hours back, on a 3-hour boundary
$steps = 12                                 # 12 x 3 hours = 36 hours
$out = @{}
$owner = @{}                                # call sign -> lineup that supplied it

foreach ($lu in $lineups) {
    for ($i = 0; $i -lt $steps; $i++) {
        $t = $from + $i * 10800
        $url = "https://tvlistings.gracenote.com/api/grid?lineupId=$($lu[0])&timespan=3&headendId=$($lu[1])&country=USA&timezone=&device=$($lu[2])&postalCode=$($lu[3])&isOverride=true&time=$t&pref=16%2C128&userId=-&aid=orbebb&languagecode=en-us"
        try { $grid = Invoke-RestMethod $url -TimeoutSec 60 }
        catch { Write-Host "skip $($lu[3]) $($lu[1]) $t : $($_.Exception.Message)"; continue }
        foreach ($c in $grid.channels) {
            $b = Base $c.callSign
            if (-not $want[$b]) { continue }
            $tag = "$($lu[1])$($lu[3])"
            if ($owner[$b] -and $owner[$b] -ne $tag) { continue }
            $owner[$b] = $tag
            if (-not $out[$b]) { $out[$b] = @{} }
            foreach ($e in $c.events) {
                $s = UnixOf $e.startTime
                if ($out[$b][$s]) { continue }
                $p = $e.program
                $desc = "$($p.shortDesc)"
                if ($desc.Length -gt 200) { $desc = $desc.Substring(0, 200) }
                $out[$b][$s] = @($s, (UnixOf $e.endTime), "$($p.title)", "$($p.episodeTitle)", $desc)
            }
        }
        Start-Sleep -Milliseconds 700   # be gentle
    }
}

$ch = [ordered]@{}
foreach ($k in ($out.Keys | Sort-Object)) {
    $ch[$k] = @($out[$k].Keys | Sort-Object | ForEach-Object { , $out[$k][$_] })
}
$doc = [ordered]@{ made = $now; ch = $ch }
$json = ConvertTo-Json $doc -Depth 5 -Compress
[IO.File]::WriteAllText((Join-Path $here 'guide.json'), $json, (New-Object Text.UTF8Encoding $false))
Write-Host ("guide.json: {0} channels, {1} KB" -f $ch.Count, [int]($json.Length / 1024))
$miss = @($want.Keys | Where-Object { -not $ch.Contains($_) })
if ($miss.Count) { Write-Host ("not found: " + ($miss -join ' ')) }
