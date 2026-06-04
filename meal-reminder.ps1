Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($false -and -not ('WindowVisualEffects' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WindowVisualEffects
{
    [StructLayout(LayoutKind.Sequential)]
    private struct AccentPolicy
    {
        public int AccentState;
        public int AccentFlags;
        public int GradientColor;
        public int AnimationId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowCompositionAttributeData
    {
        public int Attribute;
        public IntPtr Data;
        public int SizeOfData;
    }

    [DllImport("user32.dll")]
    private static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WindowCompositionAttributeData data);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    public static void EnableAcrylic(IntPtr handle, int gradientColor, bool darkTitleBar)
    {
        AccentPolicy accent = new AccentPolicy();
        accent.AccentState = 4;
        accent.AccentFlags = 2;
        accent.GradientColor = gradientColor;
        accent.AnimationId = 0;

        int size = Marshal.SizeOf(accent);
        IntPtr accentPtr = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(accent, accentPtr, false);
            WindowCompositionAttributeData data = new WindowCompositionAttributeData();
            data.Attribute = 19;
            data.SizeOfData = size;
            data.Data = accentPtr;
            SetWindowCompositionAttribute(handle, ref data);
        }
        finally
        {
            Marshal.FreeHGlobal(accentPtr);
        }

        int dark = darkTitleBar ? 1 : 0;
        DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int));
        DwmSetWindowAttribute(handle, 19, ref dark, sizeof(int));
    }
}
'@
}

if (-not ('UserIdleTracker' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class UserIdleTracker
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LASTINPUTINFO
    {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    public static uint GetIdleMilliseconds()
    {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info))
        {
            return 0;
        }

        return ((uint)Environment.TickCount) - info.dwTime;
    }
}
'@
}

Set-StrictMode -Version Latest
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:AppName = '饭点提醒'
$script:BaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ConfigPath = Join-Path $script:BaseDir 'meal-reminder.config.json'
$script:LogPath = Join-Path $script:BaseDir 'meal-reminder.log'
$script:ShowRequestPath = Join-Path $script:BaseDir 'meal-reminder.show'
$script:Config = $null
$script:MainForm = $null
$script:TrayIcon = $null
$script:TrayPauseTodayItem = $null
$script:StatusLabel = $null
$script:DetailLabel = $null
$script:ClockLabel = $null
$script:ClockDateLabel = $null
$script:MainThemeControls = $null
$script:DailyReminderRows = $null
$script:ActivePopup = $null
$script:ActivePopupForm = $null
$script:ShouldExit = $false
$script:SingleInstanceMutex = $null
$script:ThemeImages = @{}
$script:ThemeIcons = @{}
$script:LastShowRequest = ''
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:Colors = [ordered]@{
    Background = [System.Drawing.Color]::FromArgb(248, 250, 252)
    Surface     = [System.Drawing.Color]::White
    Text        = [System.Drawing.Color]::FromArgb(31, 41, 55)
    Muted       = [System.Drawing.Color]::FromArgb(107, 114, 128)
    Border      = [System.Drawing.Color]::FromArgb(226, 232, 240)
    Blue        = [System.Drawing.Color]::FromArgb(59, 130, 246)
    BlueSoft    = [System.Drawing.Color]::FromArgb(219, 234, 254)
    Green       = [System.Drawing.Color]::FromArgb(34, 197, 94)
    GreenSoft   = [System.Drawing.Color]::FromArgb(220, 252, 231)
    Orange      = [System.Drawing.Color]::FromArgb(245, 158, 11)
    OrangeSoft  = [System.Drawing.Color]::FromArgb(254, 243, 199)
    Purple      = [System.Drawing.Color]::FromArgb(139, 92, 246)
    PurpleSoft  = [System.Drawing.Color]::FromArgb(237, 233, 254)
}

function New-Color {
    param(
        [int]$R,
        [int]$G,
        [int]$B
    )
    return [System.Drawing.Color]::FromArgb($R, $G, $B)
}

function Get-ThemeMode {
    param([object]$Value)

    if ($null -eq $Value) {
        return 'Light'
    }

    switch ($Value.ToString()) {
        'Dark' { return 'Dark' }
        'Kuromi' { return 'Kuromi' }
        'Pikachu' { return 'Pikachu' }
        'PigHero' { return 'PigHero' }
        default { return 'Light' }
    }
}

function Get-ThemeDisplayName {
    param([object]$Value)

    switch (Get-ThemeMode -Value $Value) {
        'Dark' { return '深色模式' }
        'Kuromi' { return '库洛米主题' }
        'Pikachu' { return '皮卡丘主题' }
        'PigHero' { return '猪猪侠主题' }
        default { return '浅色模式' }
    }
}

function Get-ThemeElementText {
    param([object]$Value)

    switch (Get-ThemeMode -Value $Value) {
        'Kuromi' { return '库洛米 | 黑紫蝴蝶结' }
        'Pikachu' { return '皮卡丘 | 闪电能量' }
        'PigHero' { return '猪猪侠 | 红甲勇气' }
        'Dark' { return '深色 | 夜间低亮' }
        default { return '浅色 | 清爽工作台' }
    }
}

function Get-ThemeWindowTitle {
    param(
        [object]$Theme,
        [string]$Suffix = ''
    )

    $baseTitle = switch (Get-ThemeMode -Value $Theme) {
        'Kuromi' { '库洛米饭点提醒' }
        'Pikachu' { '皮卡丘饭点提醒' }
        'PigHero' { '猪猪侠饭点提醒' }
        default { $script:AppName }
    }

    if ([string]::IsNullOrWhiteSpace($Suffix)) {
        return $baseTitle
    }

    return ('{0} - {1}' -f $baseTitle, $Suffix)
}

function Get-ThemeIndex {
    param([object]$Value)

    switch (Get-ThemeMode -Value $Value) {
        'Dark' { return 1 }
        'Kuromi' { return 2 }
        'Pikachu' { return 3 }
        'PigHero' { return 4 }
        default { return 0 }
    }
}

function Get-ThemeFromIndex {
    param([int]$Index)

    switch ($Index) {
        1 { return 'Dark' }
        2 { return 'Kuromi' }
        3 { return 'Pikachu' }
        4 { return 'PigHero' }
        default { return 'Light' }
    }
}

function Get-ThemeAssetPath {
    param(
        [object]$Theme,
        [ValidateSet('badge', 'popup', 'banner')] [string]$Kind
    )

    $themeMode = Get-ThemeMode -Value $Theme
    $prefix = switch ($themeMode) {
        'Kuromi' { 'kuromi' }
        'Pikachu' { 'pikachu' }
        'PigHero' { 'pighero' }
        default { $null }
    }

    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return $null
    }

    if ($Kind -eq 'banner' -and $themeMode -eq 'Pikachu') {
        return $null
    }

    $path = Join-Path $script:BaseDir ('assets\themes\{0}-{1}.png' -f $prefix, $Kind)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return $path
    }

    return $null
}

function Get-ThemeCachePath {
    param(
        [object]$Theme,
        [ValidateSet('badge', 'popup', 'banner')] [string]$Kind
    )

    $themeMode = Get-ThemeMode -Value $Theme
    $prefix = switch ($themeMode) {
        'Kuromi' { 'kuromi' }
        'Pikachu' { 'pikachu' }
        'PigHero' { 'pighero' }
        default { $null }
    }

    if ([string]::IsNullOrWhiteSpace($prefix)) {
        return $null
    }

    $cacheDir = Join-Path $script:BaseDir 'assets\themes\cache'
    return (Join-Path $cacheDir ('{0}-{1}.cache.png' -f $prefix, $Kind))
}

function Get-ThemeImage {
    param(
        [object]$Theme,
        [ValidateSet('badge', 'popup', 'banner')] [string]$Kind
    )

    $path = Get-ThemeAssetPath -Theme $Theme -Kind $Kind
    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    $key = '{0}|{1}' -f (Get-ThemeMode -Value $Theme), $Kind
    if ($script:ThemeImages.ContainsKey($key)) {
        return $script:ThemeImages[$key]
    }

    try {
        $cachePath = Get-ThemeCachePath -Theme $Theme -Kind $Kind
        if (-not [string]::IsNullOrWhiteSpace($cachePath) -and (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
            $sourceInfo = Get-Item -LiteralPath $path
            $cacheInfo = Get-Item -LiteralPath $cachePath
            if ($cacheInfo.LastWriteTimeUtc -ge $sourceInfo.LastWriteTimeUtc) {
                $stream = [System.IO.File]::Open($cachePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $cached = [System.Drawing.Image]::FromStream($stream)
                    $copy = New-Object System.Drawing.Bitmap($cached)
                    $cached.Dispose()
                    $script:ThemeImages[$key] = $copy
                    return $copy
                }
                finally {
                    $stream.Dispose()
                }
            }
        }

        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $loaded = [System.Drawing.Image]::FromStream($stream)
            $copy = if ($Kind -eq 'badge' -or $Kind -eq 'popup') {
                New-ThemeCleanImage -Source $loaded -TargetWidth 256 -TargetHeight 256 -RemoveDarkEdges $false
            }
            elseif ($Kind -eq 'banner') {
                New-ThemeCleanImage -Source $loaded -TargetWidth 1320 -TargetHeight 148 -RemoveDarkEdges $false
            }
            else {
                New-Object System.Drawing.Bitmap($loaded)
            }
            $loaded.Dispose()
            if (-not [string]::IsNullOrWhiteSpace($cachePath)) {
                $cacheDir = Split-Path -Parent $cachePath
                if (-not (Test-Path -LiteralPath $cacheDir -PathType Container)) {
                    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
                }
                try {
                    $copy.Save($cachePath, [System.Drawing.Imaging.ImageFormat]::Png)
                }
                catch {
                    Write-AppLog -Event 'ThemeImageCacheSaveFailed' -Message ('{0}：{1}' -f $cachePath, $_.Exception.Message) -Level 'WARN'
                }
            }
            $script:ThemeImages[$key] = $copy
            return $copy
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        Write-AppLog -Event 'ThemeImageLoadFailed' -Message ('{0}：{1}' -f $path, $_.Exception.Message) -Level 'WARN'
        return $null
    }
}

function Test-EdgeBackgroundColor {
    param(
        [System.Drawing.Color]$Color,
        [bool]$RemoveDarkEdges = $false
    )

    if ($Color.A -lt 12) {
        return $true
    }

    $max = [Math]::Max($Color.R, [Math]::Max($Color.G, $Color.B))
    $min = [Math]::Min($Color.R, [Math]::Min($Color.G, $Color.B))
    $range = $max - $min
    if ($Color.R -ge 218 -and $Color.G -ge 218 -and $Color.B -ge 218 -and $range -le 42) {
        return $true
    }

    if ($range -le 34 -and $max -ge 120) {
        return $true
    }

    if ($RemoveDarkEdges -and $range -le 34 -and $max -le 72) {
        return $true
    }

    return $false
}

function New-ThemeScaledImage {
    param(
        [System.Drawing.Image]$Source,
        [int]$TargetWidth,
        [int]$TargetHeight
    )

    if ($null -eq $Source) {
        return $null
    }

    $scale = [Math]::Min(($TargetWidth / $Source.Width), ($TargetHeight / $Source.Height))
    $drawWidth = [Math]::Max(1, [int]($Source.Width * $scale))
    $drawHeight = [Math]::Max(1, [int]($Source.Height * $scale))
    $x = [int](($TargetWidth - $drawWidth) / 2)
    $y = [int](($TargetHeight - $drawHeight) / 2)

    $bmp = New-Object System.Drawing.Bitmap($TargetWidth, $TargetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($Source, $x, $y, $drawWidth, $drawHeight)
    }
    finally {
        $graphics.Dispose()
    }

    return $bmp
}

function New-ThemeCleanImage {
    param(
        [System.Drawing.Image]$Source,
        [int]$TargetWidth,
        [int]$TargetHeight,
        [bool]$RemoveDarkEdges = $false
    )

    if ($null -eq $Source) {
        return $null
    }

    $scale = [Math]::Min(($TargetWidth / $Source.Width), ($TargetHeight / $Source.Height))
    $drawWidth = [Math]::Max(1, [int]($Source.Width * $scale))
    $drawHeight = [Math]::Max(1, [int]($Source.Height * $scale))
    $x = [int](($TargetWidth - $drawWidth) / 2)
    $y = [int](($TargetHeight - $drawHeight) / 2)

    $bmp = New-Object System.Drawing.Bitmap($TargetWidth, $TargetHeight, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($Source, $x, $y, $drawWidth, $drawHeight)
    }
    finally {
        $graphics.Dispose()
    }

    $width = $bmp.Width
    $height = $bmp.Height
    $visited = New-Object 'bool[]' ($width * $height)
    $queue = New-Object 'System.Collections.Generic.Queue[int]'

    $enqueuePixel = {
        param([int]$px, [int]$py)
        if ($px -lt 0 -or $py -lt 0 -or $px -ge $width -or $py -ge $height) {
            return
        }

        $index = ($py * $width) + $px
        if ($visited[$index]) {
            return
        }

        $visited[$index] = $true
        if (Test-EdgeBackgroundColor -Color $bmp.GetPixel($px, $py) -RemoveDarkEdges $RemoveDarkEdges) {
            $queue.Enqueue($index)
        }
    }

    for ($i = 0; $i -lt $width; $i++) {
        & $enqueuePixel $i 0
        & $enqueuePixel $i ($height - 1)
    }
    for ($i = 0; $i -lt $height; $i++) {
        & $enqueuePixel 0 $i
        & $enqueuePixel ($width - 1) $i
    }

    while ($queue.Count -gt 0) {
        $index = $queue.Dequeue()
        $px = $index % $width
        $py = [int][Math]::Floor($index / $width)
        $bmp.SetPixel($px, $py, [System.Drawing.Color]::Transparent)
        & $enqueuePixel ($px - 1) $py
        & $enqueuePixel ($px + 1) $py
        & $enqueuePixel $px ($py - 1)
        & $enqueuePixel $px ($py + 1)
    }

    return $bmp
}

function Set-ThemedPicture {
    param(
        [System.Windows.Forms.PictureBox]$PictureBox,
        [ValidateSet('badge', 'popup', 'banner')] [string]$Kind
    )

    if ($null -eq $PictureBox) {
        return
    }

    $image = Get-ThemeImage -Theme $script:Config.Preferences.Theme -Kind $Kind
    if ($null -eq $image) {
        $PictureBox.Image = $null
        $PictureBox.Visible = $false
        return
    }

    $PictureBox.Image = $image
    $PictureBox.Visible = $true
}

function Get-ThemeImageBackColor {
    param([object]$Theme)

    switch (Get-ThemeMode -Value $Theme) {
        'Kuromi' { return [System.Drawing.Color]::FromArgb(252, 246, 255) }
        'Pikachu' { return [System.Drawing.Color]::FromArgb(255, 252, 224) }
        default { return $script:Colors.Background }
    }
}

function Get-ThemeIcon {
    param([object]$Theme)

    $themeMode = Get-ThemeMode -Value $Theme
    if ($themeMode -eq 'Light' -or $themeMode -eq 'Dark') {
        return [System.Drawing.SystemIcons]::Information
    }

    if ($script:ThemeIcons.ContainsKey($themeMode)) {
        return $script:ThemeIcons[$themeMode]
    }

    $image = Get-ThemeImage -Theme $themeMode -Kind 'badge'
    if ($null -eq $image) {
        return [System.Drawing.SystemIcons]::Information
    }

    $bmp = New-Object System.Drawing.Bitmap(32, 32, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($image, 0, 0, 32, 32)
    }
    finally {
        $graphics.Dispose()
    }

    try {
        $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon()).Clone()
        $script:ThemeIcons[$themeMode] = $icon
        return $icon
    }
    catch {
        Write-AppLog -Event 'ThemeIconCreateFailed' -Message $_.Exception.Message -Level 'WARN'
        return [System.Drawing.SystemIcons]::Information
    }
    finally {
        $bmp.Dispose()
    }
}

function Set-FormThemeIdentity {
    param(
        [System.Windows.Forms.Form]$Form,
        [string]$Suffix = ''
    )

    if ($null -eq $Form -or $Form.IsDisposed) {
        return
    }

    $Form.Text = Get-ThemeWindowTitle -Theme $script:Config.Preferences.Theme -Suffix $Suffix
    try {
        $Form.Icon = Get-ThemeIcon -Theme $script:Config.Preferences.Theme
    }
    catch {
    }
}

function Set-ThemeColors {
    param([object]$Theme)

    $themeMode = Get-ThemeMode -Value $Theme
    if ($themeMode -eq 'Dark') {
        $script:Colors.Background = [System.Drawing.Color]::FromArgb(18, 18, 21)
        $script:Colors.Surface = [System.Drawing.Color]::FromArgb(31, 32, 36)
        $script:Colors.Text = [System.Drawing.Color]::FromArgb(236, 238, 242)
        $script:Colors.Muted = [System.Drawing.Color]::FromArgb(166, 168, 176)
        $script:Colors.Border = [System.Drawing.Color]::FromArgb(72, 75, 84)
        $script:Colors.Blue = [System.Drawing.Color]::FromArgb(96, 165, 250)
        $script:Colors.BlueSoft = [System.Drawing.Color]::FromArgb(24, 52, 80)
        $script:Colors.Green = [System.Drawing.Color]::FromArgb(74, 222, 128)
        $script:Colors.GreenSoft = [System.Drawing.Color]::FromArgb(24, 70, 48)
        $script:Colors.Orange = [System.Drawing.Color]::FromArgb(251, 191, 36)
        $script:Colors.OrangeSoft = [System.Drawing.Color]::FromArgb(92, 57, 20)
        $script:Colors.Purple = [System.Drawing.Color]::FromArgb(167, 139, 250)
        $script:Colors.PurpleSoft = [System.Drawing.Color]::FromArgb(58, 38, 92)
        return
    }

    if ($themeMode -eq 'Kuromi') {
        $script:Colors.Background = [System.Drawing.Color]::FromArgb(32, 24, 38)
        $script:Colors.Surface = [System.Drawing.Color]::FromArgb(48, 36, 57)
        $script:Colors.Text = [System.Drawing.Color]::FromArgb(248, 239, 255)
        $script:Colors.Muted = [System.Drawing.Color]::FromArgb(211, 188, 222)
        $script:Colors.Border = [System.Drawing.Color]::FromArgb(108, 77, 130)
        $script:Colors.Blue = [System.Drawing.Color]::FromArgb(233, 92, 178)
        $script:Colors.BlueSoft = [System.Drawing.Color]::FromArgb(91, 45, 78)
        $script:Colors.Green = [System.Drawing.Color]::FromArgb(178, 131, 255)
        $script:Colors.GreenSoft = [System.Drawing.Color]::FromArgb(69, 48, 104)
        $script:Colors.Orange = [System.Drawing.Color]::FromArgb(255, 171, 213)
        $script:Colors.OrangeSoft = [System.Drawing.Color]::FromArgb(91, 50, 75)
        $script:Colors.Purple = [System.Drawing.Color]::FromArgb(193, 116, 255)
        $script:Colors.PurpleSoft = [System.Drawing.Color]::FromArgb(68, 45, 88)
        return
    }

    if ($themeMode -eq 'Pikachu') {
        $script:Colors.Background = [System.Drawing.Color]::FromArgb(255, 249, 210)
        $script:Colors.Surface = [System.Drawing.Color]::FromArgb(255, 253, 235)
        $script:Colors.Text = [System.Drawing.Color]::FromArgb(69, 49, 20)
        $script:Colors.Muted = [System.Drawing.Color]::FromArgb(123, 95, 37)
        $script:Colors.Border = [System.Drawing.Color]::FromArgb(237, 199, 82)
        $script:Colors.Blue = [System.Drawing.Color]::FromArgb(218, 52, 53)
        $script:Colors.BlueSoft = [System.Drawing.Color]::FromArgb(255, 229, 216)
        $script:Colors.Green = [System.Drawing.Color]::FromArgb(55, 118, 190)
        $script:Colors.GreenSoft = [System.Drawing.Color]::FromArgb(222, 238, 255)
        $script:Colors.Orange = [System.Drawing.Color]::FromArgb(230, 170, 0)
        $script:Colors.OrangeSoft = [System.Drawing.Color]::FromArgb(255, 239, 148)
        $script:Colors.Purple = [System.Drawing.Color]::FromArgb(86, 65, 39)
        $script:Colors.PurpleSoft = [System.Drawing.Color]::FromArgb(244, 227, 170)
        return
    }

    if ($themeMode -eq 'PigHero') {
        $script:Colors.Background = [System.Drawing.Color]::FromArgb(255, 239, 236)
        $script:Colors.Surface = [System.Drawing.Color]::FromArgb(255, 250, 247)
        $script:Colors.Text = [System.Drawing.Color]::FromArgb(82, 35, 38)
        $script:Colors.Muted = [System.Drawing.Color]::FromArgb(142, 81, 78)
        $script:Colors.Border = [System.Drawing.Color]::FromArgb(240, 181, 173)
        $script:Colors.Blue = [System.Drawing.Color]::FromArgb(214, 49, 60)
        $script:Colors.BlueSoft = [System.Drawing.Color]::FromArgb(255, 222, 221)
        $script:Colors.Green = [System.Drawing.Color]::FromArgb(255, 154, 47)
        $script:Colors.GreenSoft = [System.Drawing.Color]::FromArgb(255, 232, 198)
        $script:Colors.Orange = [System.Drawing.Color]::FromArgb(239, 91, 67)
        $script:Colors.OrangeSoft = [System.Drawing.Color]::FromArgb(255, 224, 213)
        $script:Colors.Purple = [System.Drawing.Color]::FromArgb(197, 53, 86)
        $script:Colors.PurpleSoft = [System.Drawing.Color]::FromArgb(255, 221, 232)
        return
    }

    $script:Colors.Background = [System.Drawing.Color]::FromArgb(243, 246, 250)
    $script:Colors.Surface = [System.Drawing.Color]::White
    $script:Colors.Text = [System.Drawing.Color]::FromArgb(31, 41, 55)
    $script:Colors.Muted = [System.Drawing.Color]::FromArgb(107, 114, 128)
    $script:Colors.Border = [System.Drawing.Color]::FromArgb(216, 224, 235)
    $script:Colors.Blue = [System.Drawing.Color]::FromArgb(42, 101, 189)
    $script:Colors.BlueSoft = [System.Drawing.Color]::FromArgb(231, 239, 252)
    $script:Colors.Green = [System.Drawing.Color]::FromArgb(22, 150, 92)
    $script:Colors.GreenSoft = [System.Drawing.Color]::FromArgb(227, 246, 236)
    $script:Colors.Orange = [System.Drawing.Color]::FromArgb(190, 112, 24)
    $script:Colors.OrangeSoft = [System.Drawing.Color]::FromArgb(250, 237, 218)
    $script:Colors.Purple = [System.Drawing.Color]::FromArgb(106, 76, 172)
    $script:Colors.PurpleSoft = [System.Drawing.Color]::FromArgb(238, 233, 248)
}

function New-AlphaColor {
    param(
        [int]$Alpha,
        [System.Drawing.Color]$Color
    )

    return [System.Drawing.Color]::FromArgb($Alpha, $Color.R, $Color.G, $Color.B)
}

function Blend-Color {
    param(
        [System.Drawing.Color]$From,
        [System.Drawing.Color]$To,
        [double]$Amount
    )

    $amountValue = [Math]::Max(0, [Math]::Min(1, $Amount))
    $r = [int]($From.R + (($To.R - $From.R) * $amountValue))
    $g = [int]($From.G + (($To.G - $From.G) * $amountValue))
    $b = [int]($From.B + (($To.B - $From.B) * $amountValue))
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function New-RoundedRectanglePath {
    param(
        [System.Drawing.Rectangle]$Bounds,
        [int]$Radius
    )

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $diameter = [Math]::Max(2, $Radius * 2)
    $path.AddArc($Bounds.X, $Bounds.Y, $diameter, $diameter, 180, 90)
    $path.AddArc($Bounds.Right - $diameter, $Bounds.Y, $diameter, $diameter, 270, 90)
    $path.AddArc($Bounds.Right - $diameter, $Bounds.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($Bounds.X, $Bounds.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Get-AcrylicGradientColor {
    param([object]$Theme)

    $themeMode = Get-ThemeMode -Value $Theme
    $base = if ($themeMode -eq 'Dark') {
        [System.Drawing.Color]::FromArgb(18, 18, 21)
    }
    else {
        [System.Drawing.Color]::FromArgb(248, 250, 252)
    }

    $alpha = if ($themeMode -eq 'Dark') { 188 } else { 170 }
    return (($alpha -shl 24) -bor ($base.B -shl 16) -bor ($base.G -shl 8) -bor $base.R)
}

function Enable-WindowGlass {
    param([System.Windows.Forms.Form]$Form)

    Apply-AppButtonChrome -Root $Form
}

function Apply-AppButtonChrome {
    param([System.Windows.Forms.Control]$Root)

    if ($null -eq $Root -or $Root.IsDisposed) {
        return
    }

    foreach ($control in @($Root.Controls)) {
        if ($control -is [System.Windows.Forms.Button]) {
            $control.UseVisualStyleBackColor = $false
            $control.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $control.Cursor = [System.Windows.Forms.Cursors]::Hand
            $control.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
            $control.Padding = New-Object System.Windows.Forms.Padding(0)
            if ($control.FlatAppearance.BorderSize -le 0) {
                $control.FlatAppearance.BorderSize = 1
            }
            if ($control.FlatAppearance.BorderColor.ToArgb() -eq [System.Drawing.Color]::Empty.ToArgb()) {
                $control.FlatAppearance.BorderColor = $script:Colors.Border
            }
            $control.FlatAppearance.MouseOverBackColor = Blend-Color -From $control.BackColor -To $script:Colors.Border -Amount 0.38
            $control.FlatAppearance.MouseDownBackColor = Blend-Color -From $control.BackColor -To $script:Colors.Border -Amount 0.62
        }

        if ($control.Controls.Count -gt 0) {
            Apply-AppButtonChrome -Root $control
        }
    }
}

function Set-FormBackdrop {
    param([System.Windows.Forms.Form]$Form)

    if ($null -eq $Form) {
        return
    }

    $Form.BackColor = $script:Colors.Background
}

function Set-GlassPanel {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$Radius = 18
    )

    if ($null -eq $Control) {
        return
    }

    $Control.BackColor = $script:Colors.Surface
    $Control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
}

function Update-GlassPanel {
    param(
        [System.Windows.Forms.Control]$Control,
        [int]$Radius = 18,
        [int]$FillAlpha = 168
    )

    if ($null -eq $Control) {
        return
    }

    $Control.BackColor = $script:Colors.Surface
    $Control.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $Control.Invalidate()
}

function Start-FormFadeIn {
    param(
        [System.Windows.Forms.Form]$Form,
        [double]$TargetOpacity = 0.98
    )

    if ($null -eq $Form -or $Form.IsDisposed) {
        return
    }

    $Form.Opacity = 0.0
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 15
    $timer.Tag = [pscustomobject]@{
        Form = $Form
        Target = $TargetOpacity
        Step = 0
        Total = 12
    }
    $timer.Add_Tick({
        param($sender, $e)
        $state = $sender.Tag
        if ($state.Form.IsDisposed) {
            $sender.Stop()
            $sender.Dispose()
            return
        }

        $state.Step++
        $progress = [Math]::Min(1, $state.Step / $state.Total)
        $eased = 1 - [Math]::Pow((1 - $progress), 3)
        $state.Form.Opacity = $state.Target * $eased

        if ($progress -ge 1) {
            $state.Form.Opacity = $state.Target
            $sender.Stop()
            $sender.Dispose()
        }
    })
    $timer.Start()
}

function Start-ButtonColorAnimation {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor
    )

    if ($null -eq $Button -or $null -eq $Button.Tag) {
        return
    }

    $state = $Button.Tag
    if ($state.AnimationTimer) {
        $state.AnimationTimer.Stop()
        $state.AnimationTimer.Dispose()
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 14
    $timer.Tag = $Button
    $state.AnimationTimer = $timer
    $state.Step = 0
    $state.TotalSteps = 9
    $state.StartBack = $Button.BackColor
    $state.StartFore = $Button.ForeColor
    $state.TargetBack = $BackColor
    $state.TargetFore = $ForeColor

    $timer.Add_Tick({
        param($sender, $e)

        $button = [System.Windows.Forms.Button]$sender.Tag
        if ($null -eq $button -or $button.IsDisposed -or $null -eq $button.Tag) {
            $sender.Stop()
            $sender.Dispose()
            return
        }

        $state = $button.Tag
        $state.Step++
        $progress = [Math]::Min(1, $state.Step / $state.TotalSteps)
        $eased = 1 - [Math]::Pow((1 - $progress), 2)
        $button.BackColor = Blend-Color -From $state.StartBack -To $state.TargetBack -Amount $eased
        $button.ForeColor = Blend-Color -From $state.StartFore -To $state.TargetFore -Amount $eased

        if ($progress -ge 1) {
            $button.BackColor = $state.TargetBack
            $button.ForeColor = $state.TargetFore
            $state.AnimationTimer = $null
            $sender.Stop()
            $sender.Dispose()
        }
    })
    $timer.Start()
}

function Set-ButtonStyle {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor,
        [System.Drawing.Color]$BorderColor,
        [int]$BorderSize
    )

    if ($null -eq $Button) {
        return
    }

    $Button.BackColor = $BackColor
    $Button.ForeColor = $ForeColor
    $Button.UseVisualStyleBackColor = $false
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderColor = $BorderColor
    $Button.FlatAppearance.BorderSize = $BorderSize
    $Button.FlatAppearance.MouseOverBackColor = Blend-Color -From $BackColor -To $BorderColor -Amount 0.40
    $Button.FlatAppearance.MouseDownBackColor = Blend-Color -From $BackColor -To $BorderColor -Amount 0.65
    $Button.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $Button.Padding = New-Object System.Windows.Forms.Padding(0)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
}

function Set-AnimatedButtonStyle {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Drawing.Color]$BaseBack,
        [System.Drawing.Color]$BaseFore,
        [System.Drawing.Color]$HoverBack,
        [System.Drawing.Color]$PressBack,
        [System.Drawing.Color]$BorderColor,
        [int]$BorderSize = 1
    )

    if ($null -eq $Button) {
        return
    }

    $handlersAttached = $false
    if ($Button.Tag -and ($Button.Tag.PSObject.Properties.Name -contains 'GlassButton')) {
        $handlersAttached = [bool]$Button.Tag.HandlersAttached
    }

    $Button.Tag = [pscustomobject]@{
        GlassButton = $true
        BaseBack = $BaseBack
        BaseFore = $BaseFore
        HoverBack = $HoverBack
        PressBack = $PressBack
        BorderColor = $BorderColor
        BorderSize = $BorderSize
        AnimationTimer = $null
        Step = 0
        TotalSteps = 9
        StartBack = $BaseBack
        StartFore = $BaseFore
        TargetBack = $BaseBack
        TargetFore = $BaseFore
        HandlersAttached = $handlersAttached
    }

    Set-ButtonStyle -Button $Button -BackColor $BaseBack -ForeColor $BaseFore -BorderColor $BorderColor -BorderSize $BorderSize
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand

    if (-not $handlersAttached) {
        $Button.Add_MouseEnter({
            param($sender, $e)
            Start-ButtonColorAnimation -Button $sender -BackColor $sender.Tag.HoverBack -ForeColor $sender.Tag.BaseFore
        })
        $Button.Add_MouseLeave({
            param($sender, $e)
            Start-ButtonColorAnimation -Button $sender -BackColor $sender.Tag.BaseBack -ForeColor $sender.Tag.BaseFore
        })
        $Button.Add_MouseDown({
            param($sender, $e)
            Start-ButtonColorAnimation -Button $sender -BackColor $sender.Tag.PressBack -ForeColor $sender.Tag.BaseFore
        })
        $Button.Add_MouseUp({
            param($sender, $e)
            Start-ButtonColorAnimation -Button $sender -BackColor $sender.Tag.HoverBack -ForeColor $sender.Tag.BaseFore
        })
        $Button.Tag.HandlersAttached = $true
    }
}

function Ensure-AppMenuRenderer {
    if ('CodexMenuColors' -as [type]) {
        return
    }

    Add-Type -ReferencedAssemblies 'System.Drawing', 'System.Windows.Forms' -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;

public static class CodexMenuColors {
    public static int BackArgb;
    public static int ForeArgb;
    public static int HoverArgb;
    public static int BorderArgb;
    public static int SeparatorArgb;
}

public class CodexMenuColorTable : ProfessionalColorTable {
    private Color Back { get { return Color.FromArgb(CodexMenuColors.BackArgb); } }
    private Color Hover { get { return Color.FromArgb(CodexMenuColors.HoverArgb); } }
    private Color Border { get { return Color.FromArgb(CodexMenuColors.BorderArgb); } }
    private Color Separator { get { return Color.FromArgb(CodexMenuColors.SeparatorArgb); } }

    public override Color ToolStripDropDownBackground { get { return Back; } }
    public override Color MenuBorder { get { return Border; } }
    public override Color ToolStripBorder { get { return Border; } }
    public override Color ImageMarginGradientBegin { get { return Back; } }
    public override Color ImageMarginGradientMiddle { get { return Back; } }
    public override Color ImageMarginGradientEnd { get { return Back; } }
    public override Color MenuItemSelected { get { return Hover; } }
    public override Color MenuItemSelectedGradientBegin { get { return Hover; } }
    public override Color MenuItemSelectedGradientEnd { get { return Hover; } }
    public override Color MenuItemPressedGradientBegin { get { return Hover; } }
    public override Color MenuItemPressedGradientMiddle { get { return Hover; } }
    public override Color MenuItemPressedGradientEnd { get { return Hover; } }
    public override Color MenuItemBorder { get { return Border; } }
    public override Color SeparatorDark { get { return Separator; } }
    public override Color SeparatorLight { get { return Separator; } }
}
'@
}

function Apply-AppMenuTheme {
    param([System.Windows.Forms.ContextMenuStrip]$Menu)

    if ($null -eq $Menu) {
        return
    }

    Ensure-AppMenuRenderer
    $menuBack = $script:Colors.Surface
    $hoverBack = Blend-Color -From $script:Colors.Surface -To $script:Colors.Border -Amount 0.55
    $separator = Blend-Color -From $script:Colors.Border -To $script:Colors.Surface -Amount 0.25
    [CodexMenuColors]::BackArgb = $menuBack.ToArgb()
    [CodexMenuColors]::ForeArgb = $script:Colors.Text.ToArgb()
    [CodexMenuColors]::HoverArgb = $hoverBack.ToArgb()
    [CodexMenuColors]::BorderArgb = $script:Colors.Border.ToArgb()
    [CodexMenuColors]::SeparatorArgb = $separator.ToArgb()

    $Menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::Professional
    $Menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer((New-Object CodexMenuColorTable))
    $Menu.ShowImageMargin = $false
    $Menu.ShowCheckMargin = $false
    $Menu.BackColor = $menuBack
    $Menu.ForeColor = $script:Colors.Text
    $Menu.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
    $Menu.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 6)

    foreach ($item in $Menu.Items) {
        $item.BackColor = $menuBack
        $item.ForeColor = $script:Colors.Text
        $item.Font = $Menu.Font
        if ($item -is [System.Windows.Forms.ToolStripMenuItem]) {
            $item.AutoSize = $false
            $item.Height = 34
            $item.Width = 142
            $item.Padding = New-Object System.Windows.Forms.Padding(14, 0, 14, 0)
            $item.DisplayStyle = [System.Windows.Forms.ToolStripItemDisplayStyle]::Text
        }
    }
}

function Apply-MainTheme {
    if ($null -eq $script:MainThemeControls) {
        return
    }

    $c = $script:MainThemeControls
    Apply-MainThemeLayout
    Set-FormThemeIdentity -Form $c.Form
    $c.Form.BackColor = $script:Colors.Background
    $c.Form.Invalidate()
    Enable-WindowGlass -Form $c.Form

    $c.Top.BackColor = $script:Colors.Blue
    $c.Top.Invalidate()
    Set-ThemedPicture -PictureBox $c.ThemeBanner -Kind 'banner'
    Set-ThemedPicture -PictureBox $c.ThemeIcon -Kind 'badge'

    Update-GlassPanel -Control $c.ClockPanel -Radius 18 -FillAlpha 150
    Update-GlassPanel -Control $c.Card -Radius 22 -FillAlpha 162

    foreach ($label in @($c.Title, $c.Subtitle, $c.ThemeBadge, $c.Tip)) {
        if ($label) {
            $label.BackColor = $script:Colors.Background
        }
    }

    foreach ($label in @($c.ClockCaption, $script:ClockLabel, $script:ClockDateLabel, $c.StatusTitle, $script:StatusLabel, $script:DetailLabel)) {
        if ($label) {
            $label.BackColor = $script:Colors.Surface
        }
    }

    if ($script:DailyReminderRows) {
        foreach ($row in $script:DailyReminderRows.Values) {
            foreach ($label in @($row.TimeLabel, $row.StateLabel)) {
                if ($label) {
                    $label.BackColor = $script:Colors.Surface
                }
            }
            if ($row.TimeLabel) {
                $row.TimeLabel.ForeColor = $script:Colors.Text
            }
        }
    }

    $c.Title.ForeColor = $script:Colors.Text
    $c.Subtitle.ForeColor = $script:Colors.Muted
    $c.ThemeBadge.Text = Get-ThemeElementText -Value $script:Config.Preferences.Theme
    $c.ThemeBadge.ForeColor = $script:Colors.Purple
    if ($c.ThemeIcon) {
        $c.ThemeIcon.BackColor = Get-ThemeImageBackColor -Theme $script:Config.Preferences.Theme
    }
    if ($c.ThemeBanner) {
        $c.ThemeBanner.BackColor = Get-ThemeImageBackColor -Theme $script:Config.Preferences.Theme
    }
    if ($script:TrayIcon) {
        $script:TrayIcon.Icon = Get-ThemeIcon -Theme $script:Config.Preferences.Theme
        $script:TrayIcon.Text = Get-ThemeWindowTitle -Theme $script:Config.Preferences.Theme
    }
    $c.ClockCaption.ForeColor = $script:Colors.Muted
    $script:ClockLabel.ForeColor = $script:Colors.Blue
    $script:ClockDateLabel.ForeColor = $script:Colors.Muted
    $c.StatusTitle.ForeColor = $script:Colors.Text
    $script:StatusLabel.ForeColor = $script:Colors.Blue
    $script:DetailLabel.ForeColor = $script:Colors.Muted
    $c.Tip.ForeColor = $script:Colors.Muted

    $neutralBack = Blend-Color -From $script:Colors.Surface -To $script:Colors.Background -Amount 0.25
    $neutralHover = Blend-Color -From $neutralBack -To $script:Colors.Border -Amount 0.55
    $neutralPress = Blend-Color -From $neutralBack -To $script:Colors.Border -Amount 0.82
    $white = [System.Drawing.Color]::White
    $black = [System.Drawing.Color]::Black
    $companyActive = ($script:Config.Mode -eq 'Company')
    $tripActive = ($script:Config.Mode -eq 'Trip')
    $companyBack = if ($companyActive) { $script:Colors.Blue } else { $neutralBack }
    $companyFore = if ($companyActive) { $white } else { $script:Colors.Text }
    $companyHover = if ($companyActive) { Blend-Color -From $script:Colors.Blue -To $white -Amount 0.12 } else { $neutralHover }
    $companyPress = if ($companyActive) { Blend-Color -From $script:Colors.Blue -To $black -Amount 0.10 } else { $neutralPress }
    $tripBack = if ($tripActive) { $script:Colors.Orange } else { $neutralBack }
    $tripFore = if ($tripActive) { $white } else { $script:Colors.Text }
    $tripHover = if ($tripActive) { Blend-Color -From $script:Colors.Orange -To $white -Amount 0.12 } else { $neutralHover }
    $tripPress = if ($tripActive) { Blend-Color -From $script:Colors.Orange -To $black -Amount 0.10 } else { $neutralPress }
    $companyBorder = if ($companyActive) { $script:Colors.Blue } else { $script:Colors.Border }
    $tripBorder = if ($tripActive) { $script:Colors.Orange } else { $script:Colors.Border }

    Set-AnimatedButtonStyle -Button $c.BtnCompany `
        -BaseBack $companyBack `
        -BaseFore $companyFore `
        -HoverBack $companyHover `
        -PressBack $companyPress `
        -BorderColor $companyBorder
    Set-AnimatedButtonStyle -Button $c.BtnTrip `
        -BaseBack $tripBack `
        -BaseFore $tripFore `
        -HoverBack $tripHover `
        -PressBack $tripPress `
        -BorderColor $tripBorder
    Set-AnimatedButtonStyle -Button $c.BtnTest `
        -BaseBack $neutralBack `
        -BaseFore $script:Colors.Text `
        -HoverBack $neutralHover `
        -PressBack $neutralPress `
        -BorderColor $script:Colors.Border
    Set-AnimatedButtonStyle -Button $c.BtnCustom `
        -BaseBack $neutralBack `
        -BaseFore $script:Colors.Text `
        -HoverBack $neutralHover `
        -PressBack $neutralPress `
        -BorderColor $script:Colors.Border
    Set-AnimatedButtonStyle -Button $c.BtnSettings `
        -BaseBack $script:Colors.PurpleSoft `
        -BaseFore $script:Colors.Purple `
        -HoverBack (Blend-Color -From $script:Colors.PurpleSoft -To $script:Colors.Purple -Amount 0.18) `
        -PressBack (Blend-Color -From $script:Colors.PurpleSoft -To $script:Colors.Purple -Amount 0.32) `
        -BorderColor (Blend-Color -From $script:Colors.PurpleSoft -To $script:Colors.Purple -Amount 0.28)
    Set-AnimatedButtonStyle -Button $c.BtnPauseToday `
        -BaseBack $script:Colors.OrangeSoft `
        -BaseFore $script:Colors.Orange `
        -HoverBack (Blend-Color -From $script:Colors.OrangeSoft -To $script:Colors.Orange -Amount 0.18) `
        -PressBack (Blend-Color -From $script:Colors.OrangeSoft -To $script:Colors.Orange -Amount 0.32) `
        -BorderColor (Blend-Color -From $script:Colors.OrangeSoft -To $script:Colors.Orange -Amount 0.28)
    Set-AnimatedButtonStyle -Button $c.BtnExit `
        -BaseBack $script:Colors.Surface `
        -BaseFore $script:Colors.Text `
        -HoverBack (Blend-Color -From $script:Colors.Surface -To $script:Colors.Border -Amount 0.55) `
        -PressBack (Blend-Color -From $script:Colors.Surface -To $script:Colors.Border -Amount 0.82) `
        -BorderColor $script:Colors.Border
    if ($c.BtnCustom -and $c.BtnCustom.ContextMenuStrip) {
        Apply-AppMenuTheme -Menu $c.BtnCustom.ContextMenuStrip
    }
    if ($script:TrayIcon -and $script:TrayIcon.ContextMenuStrip) {
        Apply-AppMenuTheme -Menu $script:TrayIcon.ContextMenuStrip
    }
    Update-DailyReminderRows
}

function Apply-MainThemeLayout {
    if ($null -eq $script:MainThemeControls -or $null -eq $script:Config) {
        return
    }

    $c = $script:MainThemeControls
    $themeMode = Get-ThemeMode -Value $script:Config.Preferences.Theme
    if ($themeMode -eq 'Kuromi') {
        if ($c.Form.ClientSize.Width -lt 720 -or $c.Form.ClientSize.Height -lt 530) {
            $c.Form.ClientSize = New-Object System.Drawing.Size(720, 530)
        }
        $c.Form.MinimumSize = New-Object System.Drawing.Size(680, 520)
        $c.ThemeBanner.Location = New-Object System.Drawing.Point(28, 14)
        $c.ThemeBanner.Size = New-Object System.Drawing.Size(660, 86)
        $c.ThemeBanner.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $c.ThemeIcon.Location = New-Object System.Drawing.Point(28, 108)
        $c.ThemeIcon.Size = New-Object System.Drawing.Size(64, 64)
        $c.ThemeIcon.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $c.ClockPanel.Location = New-Object System.Drawing.Point(478, 110)
        $c.Subtitle.Location = New-Object System.Drawing.Point(108, 118)
        $c.ThemeBadge.Location = New-Object System.Drawing.Point(108, 146)
        $c.Card.Location = New-Object System.Drawing.Point(28, 182)
        $c.BtnCompany.Location = New-Object System.Drawing.Point(28, 422)
        $c.BtnTrip.Location = New-Object System.Drawing.Point(138, 422)
        $c.BtnTest.Location = New-Object System.Drawing.Point(248, 422)
        $c.BtnCustom.Location = New-Object System.Drawing.Point(358, 422)
        $c.BtnSettings.Location = New-Object System.Drawing.Point(468, 422)
        $c.BtnExit.Location = New-Object System.Drawing.Point(608, 422)
        $c.BtnPauseToday.Location = New-Object System.Drawing.Point(468, 480)
        $c.Tip.Location = New-Object System.Drawing.Point(28, 488)
        return
    }

    if ($c.Form.ClientSize.Width -lt 720 -or $c.Form.ClientSize.Height -gt 500) {
        $c.Form.ClientSize = New-Object System.Drawing.Size(720, 500)
    }
    $c.Form.MinimumSize = New-Object System.Drawing.Size(680, 460)
    $c.ThemeBanner.Location = New-Object System.Drawing.Point(378, 86)
    $c.ThemeBanner.Size = New-Object System.Drawing.Size(310, 22)
    $c.ThemeBanner.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $c.ThemeIcon.Location = New-Object System.Drawing.Point(28, 26)
    $c.ThemeIcon.Size = New-Object System.Drawing.Size(64, 64)
    $c.ThemeIcon.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $c.ClockPanel.Location = New-Object System.Drawing.Point(478, 28)
    $c.Subtitle.Location = New-Object System.Drawing.Point(108, 38)
    $c.ThemeBadge.Location = New-Object System.Drawing.Point(108, 66)
    $c.Card.Location = New-Object System.Drawing.Point(28, 112)
    $c.BtnCompany.Location = New-Object System.Drawing.Point(28, 356)
    $c.BtnTrip.Location = New-Object System.Drawing.Point(138, 356)
    $c.BtnTest.Location = New-Object System.Drawing.Point(248, 356)
    $c.BtnCustom.Location = New-Object System.Drawing.Point(358, 356)
    $c.BtnSettings.Location = New-Object System.Drawing.Point(468, 356)
    $c.BtnExit.Location = New-Object System.Drawing.Point(608, 356)
    $c.BtnPauseToday.Location = New-Object System.Drawing.Point(468, 414)
    $c.Tip.Location = New-Object System.Drawing.Point(28, 422)
}

function Get-StartupShortcutPath {
    $startupDir = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
    return (Join-Path $startupDir ($script:AppName + '.lnk'))
}

function Get-WorkScheduleMode {
    param([string]$Value)

    switch ([string]$Value) {
        'SingleRest' { return 'SingleRest' }
        'BigSmall' { return 'BigSmall' }
        default { return 'DoubleRest' }
    }
}

function Get-WeekendDay {
    param(
        [string]$Value,
        [string]$Default = 'Sunday'
    )

    switch ([string]$Value) {
        'Saturday' { return 'Saturday' }
        'Sunday' { return 'Sunday' }
        default {
            if ($Default -eq 'Saturday') {
                return 'Saturday'
            }
            return 'Sunday'
        }
    }
}

function Get-WeekendDayText {
    param([string]$Value)

    if ((Get-WeekendDay -Value $Value -Default 'Sunday') -eq 'Saturday') {
        return '周六'
    }
    return '周日'
}

function Get-WeekMonday {
    param([datetime]$Date)

    $dayOfWeek = [int]$Date.DayOfWeek
    $mondayOffset = if ($dayOfWeek -eq 0) { -6 } else { -($dayOfWeek - 1) }
    return $Date.Date.AddDays($mondayOffset)
}

function Get-WorkSchedule {
    if ($null -eq $script:Config -or $null -eq $script:Config.Preferences -or -not ($script:Config.Preferences.PSObject.Properties.Name -contains 'WorkSchedule')) {
        return (Get-DefaultConfig).Preferences.WorkSchedule
    }

    $work = $script:Config.Preferences.WorkSchedule
    if ($null -eq $work) {
        return (Get-DefaultConfig).Preferences.WorkSchedule
    }

    $work.Mode = Get-WorkScheduleMode -Value $work.Mode
    $work.SingleRestDay = Get-WeekendDay -Value $work.SingleRestDay -Default 'Sunday'
    $work.BigSmallWorkDay = Get-WeekendDay -Value $work.BigSmallWorkDay -Default 'Saturday'
    return $work
}

function Get-WorkScheduleText {
    $work = Get-WorkSchedule
    switch (Get-WorkScheduleMode -Value $work.Mode) {
        'SingleRest' {
            return ('工作制：单休（{0}休）' -f (Get-WeekendDayText -Value $work.SingleRestDay))
        }
        'BigSmall' {
            return ('工作制：大小周（小周{0}上班）' -f (Get-WeekendDayText -Value $work.BigSmallWorkDay))
        }
        default {
            return '工作制：双休'
        }
    }
}

function Test-WorkDate {
    param([datetime]$Date)

    $date = $Date.Date
    $dow = $date.DayOfWeek
    if ($dow -ne [System.DayOfWeek]::Saturday -and $dow -ne [System.DayOfWeek]::Sunday) {
        return $true
    }

    $work = Get-WorkSchedule
    switch (Get-WorkScheduleMode -Value $work.Mode) {
        'SingleRest' {
            $restDay = Get-WeekendDay -Value $work.SingleRestDay -Default 'Sunday'
            if ($restDay -eq 'Saturday') {
                return ($dow -eq [System.DayOfWeek]::Sunday)
            }
            return ($dow -eq [System.DayOfWeek]::Saturday)
        }
        'BigSmall' {
            $anchor = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$work.BigSmallAnchorMonday)) {
                try {
                    $anchor = [datetime]::ParseExact([string]$work.BigSmallAnchorMonday, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                catch {
                    $anchor = $null
                }
            }
            if ($null -eq $anchor) {
                $anchor = Get-WeekMonday -Date (Get-Date)
            }

            $weekOffset = [int][Math]::Floor(((Get-WeekMonday -Date $date) - $anchor.Date).TotalDays / 7)
            $isSmallWeek = ($weekOffset % 2 -eq 0)
            if (-not $isSmallWeek) {
                return $false
            }

            $workDay = Get-WeekendDay -Value $work.BigSmallWorkDay -Default 'Saturday'
            if ($workDay -eq 'Sunday') {
                return ($dow -eq [System.DayOfWeek]::Sunday)
            }
            return ($dow -eq [System.DayOfWeek]::Saturday)
        }
        default {
            return $false
        }
    }
}

function Test-AutoStartEnabled {
    return (Test-Path -LiteralPath (Get-StartupShortcutPath) -PathType Leaf)
}

function Set-AutoStartEnabled {
    param([bool]$Enabled)

    $shortcutPath = Get-StartupShortcutPath
    if (-not $Enabled) {
        if (Test-Path -LiteralPath $shortcutPath) {
            Remove-Item -LiteralPath $shortcutPath -Force
        }
        return
    }

    $launcherPath = Join-Path $script:BaseDir 'meal-reminder.vbs'
    if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
        throw '找不到启动脚本 meal-reminder.vbs。'
    }

    $wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $wscriptPath
    $shortcut.Arguments = '"' + $launcherPath + '"'
    $shortcut.WorkingDirectory = $script:BaseDir
    $shortcut.WindowStyle = 7
    $shortcut.Description = $script:AppName
    $shortcut.Save()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

function Get-DefaultConfig {
    return [pscustomobject]@{
        Version = 8
        Mode = 'Company'
        Preferences = [pscustomobject]@{
            Theme = 'Light'
            SoundEnabled = $true
            StrongPopup = $false
            FocusDoNotDisturb = [pscustomobject]@{
                Enabled = $false
                IdleSeconds = 60
                MaxDelayMinutes = 10
            }
            WorkSchedule = [pscustomobject]@{
                Mode = 'DoubleRest'
                SingleRestDay = 'Sunday'
                BigSmallWorkDay = 'Saturday'
                BigSmallAnchorMonday = $null
            }
        }
        SingleReminder = [pscustomobject]@{
            Enabled = $false
            At = $null
            Triggered = $false
            ScheduleMode = 'Relative'
            Label = '单次提醒'
            Message = '你设置的单次提醒时间到了。'
        }
        SnoozeReminder = [pscustomobject]@{
            Enabled = $false
            Until = $null
            Title = ''
            Message = ''
            KeyName = ''
        }
        TodayPause = [pscustomobject]@{
            Enabled = $false
            Until = $null
        }
        DailyReminders = [pscustomobject]@{
            Lunch = [pscustomobject]@{
                Enabled = $true
                Time = '11:27'
                Title = '午饭时间到'
                Message = '中午 11:27 到啦，先去吃饭。'
                LastFiredDate = $null
            }
            Dinner = [pscustomobject]@{
                Enabled = $true
                Time = '17:37'
                Title = '晚饭时间到'
                Message = '下午 17:37 到啦，去吃晚饭。'
                LastFiredDate = $null
            }
            Overtime = [pscustomobject]@{
                Enabled = $true
                Time = '20:58'
                Title = '加班结束'
                Message = '晚上 20:58 到啦，今天可以收工了。'
                LastFiredDate = $null
            }
        }
        CustomReminders = @()
    }
}

function Merge-Config {
    param([object]$Loaded)

    $default = Get-DefaultConfig
    if ($null -eq $Loaded) {
        return $default
    }

    $loadedVersion = 0
    if ($Loaded.PSObject.Properties.Name -contains 'Version') {
        try {
            $loadedVersion = [int]$Loaded.Version
        }
        catch {
            $loadedVersion = 0
        }
    }

    if ($Loaded.PSObject.Properties.Name -contains 'Mode' -and $Loaded.Mode) {
        $default.Mode = [string]$Loaded.Mode
    }

    if ($Loaded.PSObject.Properties.Name -contains 'Preferences' -and $Loaded.Preferences) {
        if ($Loaded.Preferences.PSObject.Properties.Name -contains 'Theme') {
            $default.Preferences.Theme = Get-ThemeMode -Value $Loaded.Preferences.Theme
        }
        if ($Loaded.Preferences.PSObject.Properties.Name -contains 'SoundEnabled') {
            $default.Preferences.SoundEnabled = [bool]$Loaded.Preferences.SoundEnabled
        }
        if ($Loaded.Preferences.PSObject.Properties.Name -contains 'StrongPopup') {
            $default.Preferences.StrongPopup = [bool]$Loaded.Preferences.StrongPopup
        }
        if ($Loaded.Preferences.PSObject.Properties.Name -contains 'FocusDoNotDisturb' -and $Loaded.Preferences.FocusDoNotDisturb) {
            $focus = $Loaded.Preferences.FocusDoNotDisturb
            if ($focus.PSObject.Properties.Name -contains 'Enabled') {
                $default.Preferences.FocusDoNotDisturb.Enabled = [bool]$focus.Enabled
            }
            if ($focus.PSObject.Properties.Name -contains 'IdleSeconds') {
                $default.Preferences.FocusDoNotDisturb.IdleSeconds = [Math]::Max(3, [Math]::Min(60, [int]$focus.IdleSeconds))
            }
            if ($focus.PSObject.Properties.Name -contains 'MaxDelayMinutes') {
                $default.Preferences.FocusDoNotDisturb.MaxDelayMinutes = [Math]::Max(1, [Math]::Min(120, [int]$focus.MaxDelayMinutes))
            }
        }
        if ($Loaded.Preferences.PSObject.Properties.Name -contains 'WorkSchedule' -and $Loaded.Preferences.WorkSchedule) {
            $work = $Loaded.Preferences.WorkSchedule
            if ($work.PSObject.Properties.Name -contains 'Mode') {
                $default.Preferences.WorkSchedule.Mode = Get-WorkScheduleMode -Value $work.Mode
            }
            if ($work.PSObject.Properties.Name -contains 'SingleRestDay') {
                $default.Preferences.WorkSchedule.SingleRestDay = Get-WeekendDay -Value $work.SingleRestDay -Default 'Sunday'
            }
            if ($work.PSObject.Properties.Name -contains 'BigSmallWorkDay') {
                $default.Preferences.WorkSchedule.BigSmallWorkDay = Get-WeekendDay -Value $work.BigSmallWorkDay -Default 'Saturday'
            }
            if ($work.PSObject.Properties.Name -contains 'BigSmallAnchorMonday') {
                $default.Preferences.WorkSchedule.BigSmallAnchorMonday = $work.BigSmallAnchorMonday
            }
        }
    }

    if ($Loaded.PSObject.Properties.Name -contains 'SingleReminder' -and $Loaded.SingleReminder) {
        foreach ($prop in 'Enabled', 'At', 'Triggered', 'ScheduleMode', 'Label', 'Message') {
            if ($Loaded.SingleReminder.PSObject.Properties.Name -contains $prop) {
                $default.SingleReminder.$prop = $Loaded.SingleReminder.$prop
            }
        }
    }

    if ($Loaded.PSObject.Properties.Name -contains 'SnoozeReminder' -and $Loaded.SnoozeReminder) {
        foreach ($prop in 'Enabled', 'Until', 'Title', 'Message', 'KeyName') {
            if ($Loaded.SnoozeReminder.PSObject.Properties.Name -contains $prop) {
                $default.SnoozeReminder.$prop = $Loaded.SnoozeReminder.$prop
            }
        }
    }

    if ($Loaded.PSObject.Properties.Name -contains 'TodayPause' -and $Loaded.TodayPause) {
        foreach ($prop in 'Enabled', 'Until') {
            if ($Loaded.TodayPause.PSObject.Properties.Name -contains $prop) {
                $default.TodayPause.$prop = $Loaded.TodayPause.$prop
            }
        }
    }

    if ($Loaded.PSObject.Properties.Name -contains 'DailyReminders' -and $Loaded.DailyReminders) {
        foreach ($name in 'Lunch', 'Dinner', 'Overtime') {
            if ($Loaded.DailyReminders.PSObject.Properties.Name -contains $name) {
                foreach ($prop in 'Enabled', 'Time', 'Title', 'Message', 'LastFiredDate') {
                    if ($Loaded.DailyReminders.$name.PSObject.Properties.Name -contains $prop) {
                        $default.DailyReminders.$name.$prop = $Loaded.DailyReminders.$name.$prop
                    }
                }
            }
        }
    }

    if ($loadedVersion -lt 4) {
        foreach ($name in 'Lunch', 'Dinner', 'Overtime') {
            $default.DailyReminders.$name.Enabled = $true
        }
    }

    if ($Loaded.PSObject.Properties.Name -contains 'CustomReminders' -and $Loaded.CustomReminders) {
        $customItems = New-Object System.Collections.Generic.List[object]
        foreach ($item in @($Loaded.CustomReminders)) {
            if ($null -eq $item) {
                continue
            }

            $timeText = if ($item.PSObject.Properties.Name -contains 'Time') { [string]$item.Time } else { '' }
            try {
                [void](Get-TimeOfDay -Value $timeText)
            }
            catch {
                continue
            }

            $idText = if ($item.PSObject.Properties.Name -contains 'Id' -and -not [string]::IsNullOrWhiteSpace([string]$item.Id)) {
                [string]$item.Id
            }
            else {
                [guid]::NewGuid().ToString('N')
            }

            $titleText = if ($item.PSObject.Properties.Name -contains 'Title' -and -not [string]::IsNullOrWhiteSpace([string]$item.Title)) {
                [string]$item.Title
            }
            else {
                '自定义提醒'
            }

            $messageText = if ($item.PSObject.Properties.Name -contains 'Message' -and -not [string]::IsNullOrWhiteSpace([string]$item.Message)) {
                [string]$item.Message
            }
            else {
                '你设置的自定义提醒时间到了。'
            }

            $enabledValue = $true
            if ($item.PSObject.Properties.Name -contains 'Enabled') {
                $enabledValue = [bool]$item.Enabled
            }

            $lastFiredValue = $null
            if ($item.PSObject.Properties.Name -contains 'LastFiredDate') {
                $lastFiredValue = $item.LastFiredDate
            }

            $strongValue = $false
            if ($item.PSObject.Properties.Name -contains 'Strong') {
                $strongValue = [bool]$item.Strong
            }

            $soundValue = $true
            if ($item.PSObject.Properties.Name -contains 'Sound') {
                $soundValue = [bool]$item.Sound
            }

            $customItems.Add([pscustomobject]@{
                Id = $idText
                Enabled = $enabledValue
                Time = $timeText
                Title = $titleText
                Message = $messageText
                LastFiredDate = $lastFiredValue
                Strong = $strongValue
                Sound = $soundValue
            })
        }
        $default.CustomReminders = @($customItems)
    }

    return $default
}

function Read-Utf8Text {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Write-Utf8Text {
    param(
        [string]$Path,
        [string]$Text
    )
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Add-Utf8Line {
    param(
        [string]$Path,
        [string]$Text
    )
    [System.IO.File]::AppendAllText($Path, $Text + [Environment]::NewLine, $script:Utf8NoBom)
}

function Load-Config {
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $raw = Read-Utf8Text -Path $script:ConfigPath
            if ([string]::IsNullOrWhiteSpace($raw)) {
                return Get-DefaultConfig
            }
            return (Merge-Config -Loaded (ConvertFrom-Json -InputObject $raw))
        }
        catch {
            Write-AppLog -Event 'ConfigLoadFailed' -Message $_.Exception.Message -Level 'ERROR'
            return Get-DefaultConfig
        }
    }

    return Get-DefaultConfig
}

function Save-Config {
    $json = $script:Config | ConvertTo-Json -Depth 8
    Write-Utf8Text -Path $script:ConfigPath -Text $json
}

function Write-AppLog {
    param(
        [string]$Event,
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string]$Level = 'INFO'
    )

    try {
        $safeEvent = if ([string]::IsNullOrWhiteSpace($Event)) { 'General' } else { $Event.Trim() }
        $safeMessage = if ($null -eq $Message) { '' } else { ($Message -replace "(`r`n|`n|`r)", ' ').Trim() }
        $line = '{0} [{1}] {2} - {3}' -f ([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')), $Level, $safeEvent, $safeMessage
        Add-Utf8Line -Path $script:LogPath -Text $line
    }
    catch {
    }
}

function Get-RecentLogText {
    param([int]$Tail = 120)

    if (-not (Test-Path -LiteralPath $script:LogPath)) {
        return '暂无日志。'
    }

    try {
        return ((Read-Utf8Text -Path $script:LogPath) -split "\r\n|\n|\r" | Select-Object -Last $Tail) -join [Environment]::NewLine
    }
    catch {
        return ('读取日志失败：{0}' -f $_.Exception.Message)
    }
}

function Ensure-DateTime {
    param([object]$Value)
    if ($null -eq $Value -or $Value -eq '') {
        return $null
    }
    try {
        return [datetime]::Parse($Value.ToString())
    }
    catch {
        return $null
    }
}

function Get-TimeOfDay {
    param([string]$Value)
    return [datetime]::ParseExact($Value, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture).TimeOfDay
}

function Get-ScheduledDateTime {
    param([string]$TimeText)
    return ([datetime]::Today).Add((Get-TimeOfDay -Value $TimeText))
}

function Get-SnoozeUntil {
    if ($null -eq $script:Config -or $null -eq $script:Config.SnoozeReminder) {
        return $null
    }

    return Ensure-DateTime $script:Config.SnoozeReminder.Until
}

function Test-SnoozeActive {
    param([datetime]$Now = ([datetime]::Now))

    if ($null -eq $script:Config -or $null -eq $script:Config.SnoozeReminder) {
        return $false
    }

    if (-not [bool]$script:Config.SnoozeReminder.Enabled) {
        return $false
    }

    $until = Get-SnoozeUntil
    return ($null -ne $until -and $until -gt $Now)
}

function Set-SnoozeReminder {
    param(
        [string]$TitleText,
        [string]$MessageText,
        [string]$KeyName,
        [int]$Minutes
    )

    $until = ([datetime]::Now).AddMinutes($Minutes)
    $script:Config.SnoozeReminder.Enabled = $true
    $script:Config.SnoozeReminder.Until = $until.ToString('o')
    $script:Config.SnoozeReminder.Title = $TitleText
    $script:Config.SnoozeReminder.Message = $MessageText
    $script:Config.SnoozeReminder.KeyName = $KeyName
    Save-Config
    Update-MainStatus
    Write-AppLog -Event 'SnoozeSet' -Message ('{0} 贪睡 {1} 分钟，到 {2:yyyy-MM-dd HH:mm:ss}' -f $TitleText, $Minutes, $until)
    Show-Toast -Message ('已贪睡 {0} 分钟，{1:HH:mm} 再提醒' -f $Minutes, $until) -Accent $script:Colors.Orange
}

function Get-SingleReminderTimeOfDay {
    param([string]$At)
    if ([string]::IsNullOrWhiteSpace($At)) { return $null }
    if ($At.Length -eq 5 -and $At[2] -eq ':') {
        try { return Get-TimeOfDay -Value $At } catch { return $null }
    }
    $dt = Ensure-DateTime $At
    if ($null -eq $dt) { return $null }
    return $dt.TimeOfDay
}

function ConvertTo-SingleReminderDateTime {
    param(
        [object]$At,
        [datetime]$BaseNow = ([datetime]::Now)
    )

    if ($null -eq $At -or [string]::IsNullOrWhiteSpace($At.ToString())) {
        return $null
    }

    $text = $At.ToString()
    if ($text.Length -eq 5 -and $text[2] -eq ':') {
        try {
            $tod = Get-TimeOfDay -Value $text
        }
        catch {
            return $null
        }

        $candidate = $BaseNow.Date.Add($tod)
        if ($candidate -le $BaseNow) {
            $candidate = $candidate.AddDays(1)
        }
        return $candidate
    }

    $dt = Ensure-DateTime $text
    if ($null -ne $dt) {
        return $dt
    }

    return $null
}

function Get-SingleReminderScheduleMode {
    param([object]$Value)

    if ($null -eq $Value) {
        return 'Relative'
    }

    switch ($Value.ToString()) {
        'ClockTime' { return 'ClockTime' }
        default { return 'Relative' }
    }
}

function Get-SingleReminderCandidate {
    param(
        [int]$Hour,
        [int]$Minute,
        [string]$ScheduleMode,
        [datetime]$BaseNow
    )

    if ((Get-SingleReminderScheduleMode -Value $ScheduleMode) -eq 'ClockTime') {
        $candidate = $BaseNow.Date.AddHours($Hour).AddMinutes($Minute)
        if ($candidate -le $BaseNow) {
            $candidate = $candidate.AddDays(1)
        }
        return $candidate
    }

    return $BaseNow.AddHours($Hour).AddMinutes($Minute)
}

function Request-MainWindowShow {
    try {
        Set-Content -LiteralPath $script:ShowRequestPath -Value ([datetime]::Now.ToString('o')) -Encoding UTF8
    }
    catch {
        Write-AppLog -Event 'ShowRequestFailed' -Message $_.Exception.Message -Level 'WARN'
    }
}

function Initialize-ShowRequestState {
    if (Test-Path -LiteralPath $script:ShowRequestPath -PathType Leaf) {
        try {
            $script:LastShowRequest = (Get-Content -LiteralPath $script:ShowRequestPath -Raw -Encoding UTF8).Trim()
        }
        catch {
            $script:LastShowRequest = ''
        }
    }
}

function Check-MainWindowShowRequest {
    if (-not (Test-Path -LiteralPath $script:ShowRequestPath -PathType Leaf)) {
        return
    }

    try {
        $request = (Get-Content -LiteralPath $script:ShowRequestPath -Raw -Encoding UTF8).Trim()
    }
    catch {
        return
    }

    if ([string]::IsNullOrWhiteSpace($request) -or $request -eq $script:LastShowRequest) {
        return
    }

    $script:LastShowRequest = $request
    Write-AppLog -Event 'ShowRequestReceived' -Message '重复启动请求显示主界面'
    Show-MainWindow
}

function Initialize-SingleInstance {
    $createdNew = $false
    $mutexName = 'Local\meal-reminder-single-instance'
    $mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
    if (-not $createdNew) {
        $mutex.Dispose()
        return $false
    }

    $script:SingleInstanceMutex = $mutex
    return $true
}

function Release-SingleInstance {
    if ($null -eq $script:SingleInstanceMutex) {
        return
    }

    try {
        [void]$script:SingleInstanceMutex.ReleaseMutex()
    }
    catch {
    }
    finally {
        $script:SingleInstanceMutex.Dispose()
        $script:SingleInstanceMutex = $null
    }
}

function Get-ModeLabel {
    if ($script:Config.Mode -eq 'Trip') {
        return '出差中'
    }
    return '公司上班'
}

function Get-SingleReminderText {
    $single = $script:Config.SingleReminder
    if (-not $single.Enabled -or [string]::IsNullOrWhiteSpace($single.At)) {
        return '未设置'
    }

    $when = ConvertTo-SingleReminderDateTime -At $single.At -BaseNow ([datetime]::Now)
    if ($null -eq $when) {
        return '未设置'
    }

    if ($single.Triggered) {
        return ('已完成，时间：{0}' -f (Format-SingleReminderDisplay -At $when))
    }

    return ('{0}，状态：等待触发' -f (Format-SingleReminderDisplay -At $when))
}

function Format-SingleReminderDisplay {
    param([datetime]$At)

    $today = [datetime]::Today
    $tomorrow = $today.AddDays(1)
    $dateOnly = $At.Date

    if ($dateOnly -eq $today) {
        return ('今天 {0}' -f $At.ToString('HH:mm'))
    }

    if ($dateOnly -eq $tomorrow) {
        return ('明天 {0}' -f $At.ToString('HH:mm'))
    }

    return $At.ToString('yyyy-MM-dd HH:mm')
}

function Format-ReminderTime {
    param(
        [int]$Hour,
        [int]$Minute
    )

    return ('{0:D2}:{1:D2}' -f $Hour, $Minute)
}

function Get-DailyReminderLabel {
    param([string]$Name)

    switch ($Name) {
        'Lunch' { return '午饭' }
        'Dinner' { return '晚饭' }
        'Overtime' { return '加班结束' }
        default { return $Name }
    }
}

function Get-DailyReminderMessage {
    param(
        [string]$Name,
        [string]$TimeText
    )

    switch ($Name) {
        'Lunch' { return ('中午 {0} 到啦，先去吃饭。' -f $TimeText) }
        'Dinner' { return ('下午 {0} 到啦，去吃晚饭。' -f $TimeText) }
        'Overtime' { return ('晚上 {0} 到啦，今天可以收工了。' -f $TimeText) }
        default { return ('{0} 到啦。' -f $TimeText) }
    }
}

function Get-DailyReminderTimeParts {
    param(
        [string]$TimeText,
        [int]$DefaultHour,
        [int]$DefaultMinute
    )

    try {
        $time = Get-TimeOfDay -Value $TimeText
        return [pscustomobject]@{
            Hour = [int]$time.Hours
            Minute = [int]$time.Minutes
        }
    }
    catch {
        return [pscustomobject]@{
            Hour = $DefaultHour
            Minute = $DefaultMinute
        }
    }
}

function Set-DailyReminderSettings {
    param(
        [string]$Name,
        [bool]$Enabled,
        [string]$TimeText
    )

    $item = $script:Config.DailyReminders.$Name
    $changed = ([bool]$item.Enabled -ne $Enabled) -or ([string]$item.Time -ne $TimeText)
    $item.Enabled = $Enabled
    $item.Time = $TimeText
    $item.Message = Get-DailyReminderMessage -Name $Name -TimeText $TimeText

    if ($changed) {
        $item.LastFiredDate = $null
    }
}

function Get-NextDailyText {
    $result = New-Object System.Collections.Generic.List[string]
    $snoozeUntil = Get-SnoozeUntil
    foreach ($name in 'Lunch', 'Dinner', 'Overtime') {
        $item = $script:Config.DailyReminders.$name
        $state = if ($script:Config.Mode -eq 'Trip') {
            '出差屏蔽'
        }
        elseif (-not $item.Enabled) {
            '单独屏蔽'
        }
        elseif ((Test-SnoozeActive) -and $script:Config.SnoozeReminder.KeyName -eq $name) {
            '贪睡到 {0:HH:mm}' -f $snoozeUntil
        }
        elseif ($item.LastFiredDate -eq (Get-Date).ToString('yyyy-MM-dd')) {
            '今日已提醒'
        }
        else {
            '待提醒'
        }
        $result.Add(('{0} {1} ({2})' -f (Get-DailyReminderLabel -Name $name), $item.Time, $state))
    }
    return ($result -join '  |  ')
}

function Get-DailyReminderStateText {
    param([string]$Name)

    $item = $script:Config.DailyReminders.$Name
    if ($script:Config.Mode -eq 'Trip') {
        if ($item.Enabled) {
            return '出差中，暂不提醒'
        }
        return '出差中，且已单独屏蔽'
    }

    if (-not $item.Enabled) {
        return '已单独屏蔽'
    }

    if ((Test-SnoozeActive) -and $script:Config.SnoozeReminder.KeyName -eq $Name) {
        return ('贪睡中，{0:HH:mm} 再提醒' -f (Get-SnoozeUntil))
    }

    if ($item.LastFiredDate -eq (Get-Date).ToString('yyyy-MM-dd')) {
        return '今日已提醒'
    }

    return '提醒已开启'
}

function Update-DailyReminderRows {
    if ($null -eq $script:DailyReminderRows) {
        return
    }

    foreach ($name in 'Lunch', 'Dinner', 'Overtime') {
        if (-not $script:DailyReminderRows.ContainsKey($name)) {
            continue
        }

        $row = $script:DailyReminderRows[$name]
        $item = $script:Config.DailyReminders.$name
        $isEnabled = [bool]$item.Enabled
        $row.TimeLabel.Text = ('{0}  {1}' -f (Get-DailyReminderLabel -Name $name), $item.Time)
        $row.StateLabel.Text = Get-DailyReminderStateText -Name $name
        $row.ToggleButton.Text = if ($isEnabled) { '屏蔽' } else { '开启' }

        if ($script:Config.Mode -eq 'Trip' -or ((Test-SnoozeActive) -and $script:Config.SnoozeReminder.KeyName -eq $name)) {
            $row.StateLabel.ForeColor = $script:Colors.Orange
        }
        elseif ($isEnabled) {
            $row.StateLabel.ForeColor = $script:Colors.Green
        }
        else {
            $row.StateLabel.ForeColor = $script:Colors.Muted
        }

        $toggleBack = Blend-Color -From $script:Colors.Surface -To $script:Colors.Background -Amount 0.25
        $toggleHover = Blend-Color -From $toggleBack -To $script:Colors.Border -Amount 0.55
        $togglePress = Blend-Color -From $toggleBack -To $script:Colors.Border -Amount 0.82
        if ($isEnabled) {
            Set-AnimatedButtonStyle -Button $row.ToggleButton `
                -BaseBack $toggleBack `
                -BaseFore $script:Colors.Orange `
                -HoverBack $toggleHover `
                -PressBack $togglePress `
                -BorderColor $script:Colors.Border
        }
        else {
            Set-AnimatedButtonStyle -Button $row.ToggleButton `
                -BaseBack $toggleBack `
                -BaseFore $script:Colors.Green `
                -HoverBack $toggleHover `
                -PressBack $togglePress `
                -BorderColor $script:Colors.Border
        }
    }
}

function Toggle-DailyReminderBlock {
    param([string]$Name)

    $item = $script:Config.DailyReminders.$Name
    $item.Enabled = -not [bool]$item.Enabled
    Save-Config
    Update-MainStatus

    $action = if ($item.Enabled) { '已开启' } else { '已屏蔽' }
    $accent = if ($item.Enabled) { $script:Colors.Green } else { $script:Colors.Orange }
    Write-AppLog -Event 'DailyToggle' -Message ('{0} {1}' -f (Get-DailyReminderLabel -Name $Name), $action)
    Show-Toast -Message ('{0}提醒{1}' -f (Get-DailyReminderLabel -Name $Name), $action) -Accent $accent
}

function Get-CustomReminderList {
    if ($null -eq $script:Config -or -not ($script:Config.PSObject.Properties.Name -contains 'CustomReminders') -or $null -eq $script:Config.CustomReminders) {
        return @()
    }

    return @($script:Config.CustomReminders)
}

function New-CustomReminder {
    param(
        [string]$TimeText = '09:00',
        [string]$Title = '自定义提醒',
        [string]$Message = '你设置的自定义提醒时间到了。',
        [bool]$Enabled = $true,
        [bool]$Strong = $false,
        [bool]$Sound = $true
    )

    return [pscustomobject]@{
        Id = [guid]::NewGuid().ToString('N')
        Enabled = $Enabled
        Time = $TimeText
        Title = $Title
        Message = $Message
        LastFiredDate = $null
        Strong = $Strong
        Sound = $Sound
    }
}

function Get-CustomReminderDisplayText {
    param([object]$Item)

    if ($null -eq $Item) {
        return ''
    }

    $state = if (-not [bool]$Item.Enabled) {
        '已关闭'
    }
    elseif ($script:Config.Mode -eq 'Trip') {
        '出差屏蔽'
    }
    elseif ($Item.LastFiredDate -eq (Get-Date).ToString('yyyy-MM-dd')) {
        '今日已提醒'
    }
    else {
        '待提醒'
    }

    return ('{0}  {1}  [{2}]' -f $Item.Time, $Item.Title, $state)
}

function Get-NextCustomText {
    $items = Get-CustomReminderList | Where-Object { [bool]$_.Enabled }
    if (-not $items -or @($items).Count -eq 0) {
        return '自定义：未设置'
    }

    $enabledCount = @($items).Count
    $nextItems = @($items | Sort-Object Time | Select-Object -First 2 | ForEach-Object { '{0} {1}' -f $_.Time, $_.Title })
    return ('自定义：{0}个开启，最近 {1}' -f $enabledCount, ($nextItems -join '、'))
}

function Get-MealStats {
    $empty = [pscustomobject]@{
        ThisWeekTotal = 0
        ThisWeekOnTimeCount = 0
        ThisWeekLunchCount = 0
        ThisWeekDinnerCount = 0
        ThisWeekDelayedCount = 0
        ThisWeekNotOnTimeCount = 0
        DisplayString = ''
    }

    $today = [datetime]::Today
    $monday = Get-WeekMonday -Date $today
    $sunday = $monday.AddDays(6)

    $workDates = New-Object 'System.Collections.Generic.HashSet[string]'
    $cursor = $monday
    while ($cursor -le $today) {
        if (Test-WorkDate -Date $cursor) {
            [void]$workDates.Add($cursor.ToString('yyyy-MM-dd'))
        }
        $cursor = $cursor.AddDays(1)
    }

    if (-not (Test-Path -LiteralPath $script:LogPath -PathType Leaf)) {
        $empty.ThisWeekTotal = $workDates.Count
        return $empty
    }

    try {
        $logText = Read-Utf8Text -Path $script:LogPath
    }
    catch {
        $empty.ThisWeekTotal = $workDates.Count
        return $empty
    }

    if ([string]::IsNullOrWhiteSpace($logText)) {
        $empty.ThisWeekTotal = $workDates.Count
        return $empty
    }

    $lunchDates = New-Object 'System.Collections.Generic.HashSet[string]'
    $dinnerDates = New-Object 'System.Collections.Generic.HashSet[string]'
    $delayedDates = New-Object 'System.Collections.Generic.HashSet[string]'
    $recordDates = New-Object 'System.Collections.Generic.HashSet[string]'
    $dailyPattern = '^(\d{4}-\d{2}-\d{2})\s+\d{2}:\d{2}:\d{2}\s+\[INFO\]\s+DailyFired\s+-\s+(午饭|晚饭)\s+'
    $snoozePattern = '^(\d{4}-\d{2}-\d{2})\s+\d{2}:\d{2}:\d{2}\s+\[INFO\]\s+SnoozeSet\s+-\s+.*(午饭|晚饭)'

    foreach ($line in ($logText -split "\r\n|\n|\r")) {
        if ($line -match $dailyPattern) {
            try {
                $logDate = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            catch {
                continue
            }

            if ($logDate -lt $monday -or $logDate -gt $sunday -or -not $workDates.Contains($Matches[1])) {
                continue
            }

            [void]$recordDates.Add($Matches[1])
            if ($Matches[2] -eq '午饭') {
                [void]$lunchDates.Add($Matches[1])
            }
            elseif ($Matches[2] -eq '晚饭') {
                [void]$dinnerDates.Add($Matches[1])
            }
        }
        elseif ($line -match $snoozePattern) {
            try {
                $logDate = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
            }
            catch {
                continue
            }

            if ($logDate -lt $monday -or $logDate -gt $sunday -or -not $workDates.Contains($Matches[1])) {
                continue
            }

            [void]$recordDates.Add($Matches[1])
            [void]$delayedDates.Add($Matches[1])
        }
    }

    $eligibleDates = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($dateText in $workDates) {
        try {
            $dateValue = [datetime]::ParseExact($dateText, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        }
        catch {
            continue
        }

        if ($dateValue -lt $today -or $recordDates.Contains($dateText)) {
            [void]$eligibleDates.Add($dateText)
        }
    }

    $onTimeDates = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($date in $lunchDates) { [void]$onTimeDates.Add($date) }
    foreach ($date in $dinnerDates) { [void]$onTimeDates.Add($date) }
    foreach ($date in @($onTimeDates)) {
        if (-not $eligibleDates.Contains($date) -or $delayedDates.Contains($date)) {
            [void]$onTimeDates.Remove($date)
        }
    }

    $notOnTimeCount = [Math]::Max(0, $eligibleDates.Count - $onTimeDates.Count)
    $display = ''
    if ($eligibleDates.Count -gt 0) {
        $display = ('本周准点吃饭 {0}/{1} 天，不准点 {2} 天' -f $onTimeDates.Count, $eligibleDates.Count, $notOnTimeCount)
    }

    return [pscustomobject]@{
        ThisWeekTotal = $eligibleDates.Count
        ThisWeekOnTimeCount = $onTimeDates.Count
        ThisWeekLunchCount = $lunchDates.Count
        ThisWeekDinnerCount = $dinnerDates.Count
        ThisWeekDelayedCount = $delayedDates.Count
        ThisWeekNotOnTimeCount = $notOnTimeCount
        DisplayString = $display
    }
}

function Update-TrayStats {
    if ($null -eq $script:TrayIcon) {
        return
    }

    $baseText = Get-ThemeWindowTitle -Theme $script:Config.Preferences.Theme
    $stats = Get-MealStats
    if ([string]::IsNullOrWhiteSpace($stats.DisplayString)) {
        $script:TrayIcon.Text = $baseText
        return
    }

    $text = ('{0} | {1}' -f $baseText, $stats.DisplayString)
    if ($text.Length -gt 63) {
        $text = $text.Substring(0, 63)
    }
    $script:TrayIcon.Text = $text
}

function Get-FocusDoNotDisturb {
    if ($null -eq $script:Config -or $null -eq $script:Config.Preferences -or -not ($script:Config.Preferences.PSObject.Properties.Name -contains 'FocusDoNotDisturb')) {
        return [pscustomobject]@{
            Enabled = $false
            IdleSeconds = 60
            MaxDelayMinutes = 10
        }
    }

    return $script:Config.Preferences.FocusDoNotDisturb
}

function Get-FocusIdleSeconds {
    $focus = Get-FocusDoNotDisturb
    try {
        return [Math]::Max(3, [Math]::Min(60, [int]$focus.IdleSeconds))
    }
    catch {
        return 60
    }
}

function Get-FocusMaxDelayMinutes {
    $focus = Get-FocusDoNotDisturb
    try {
        return [Math]::Max(1, [Math]::Min(120, [int]$focus.MaxDelayMinutes))
    }
    catch {
        return 10
    }
}

function Get-UserIdleSeconds {
    try {
        return [Math]::Floor(([double][UserIdleTracker]::GetIdleMilliseconds()) / 1000)
    }
    catch {
        Write-AppLog -Event 'IdleCheckFailed' -Message $_.Exception.Message -Level 'WARN'
        return 999999
    }
}

function Test-FocusDoNotDisturbActive {
    $focus = Get-FocusDoNotDisturb
    return [bool]$focus.Enabled
}

function Get-FocusDoNotDisturbText {
    if (-not (Test-FocusDoNotDisturbActive)) {
        return '专注勿扰：关闭'
    }

    return ('专注勿扰：开启，静止 {0} 秒弹，最多延迟 {1} 分钟' -f (Get-FocusIdleSeconds), (Get-FocusMaxDelayMinutes))
}

function Get-TodayPauseUntil {
    if ($null -eq $script:Config -or -not ($script:Config.PSObject.Properties.Name -contains 'TodayPause') -or $null -eq $script:Config.TodayPause) {
        return $null
    }

    return Ensure-DateTime $script:Config.TodayPause.Until
}

function Test-TodayPauseActive {
    if ($null -eq $script:Config -or -not ($script:Config.PSObject.Properties.Name -contains 'TodayPause') -or $null -eq $script:Config.TodayPause) {
        return $false
    }

    if (-not [bool]$script:Config.TodayPause.Enabled) {
        return $false
    }

    $until = Get-TodayPauseUntil
    if ($null -eq $until) {
        return $false
    }

    if ($until -le [datetime]::Now) {
        $script:Config.TodayPause.Enabled = $false
        $script:Config.TodayPause.Until = $null
        Save-Config
        return $false
    }

    return $true
}

function Get-TodayPauseText {
    if (-not (Test-TodayPauseActive)) {
        return '今日暂停：关闭'
    }

    return ('今日暂停：开启，到 {0:MM-dd HH:mm}' -f (Get-TodayPauseUntil))
}

function Set-TodayPause {
    $until = ([datetime]::Today).AddDays(1)
    $script:Config.TodayPause.Enabled = $true
    $script:Config.TodayPause.Until = $until.ToString('o')
    Save-Config
    Update-MainStatus
    Write-AppLog -Event 'TodayPauseSet' -Message ('今日提醒暂停到 {0:yyyy-MM-dd HH:mm:ss}' -f $until)
    Show-Toast -Message '今日提醒已暂停，明天自动恢复' -Accent $script:Colors.Orange
}

function Clear-TodayPause {
    if ($null -eq $script:Config -or $null -eq $script:Config.TodayPause) {
        return
    }

    $script:Config.TodayPause.Enabled = $false
    $script:Config.TodayPause.Until = $null
    Save-Config
    Update-MainStatus
    Write-AppLog -Event 'TodayPauseCleared' -Message '今日暂停已取消'
    Show-Toast -Message '今日提醒已恢复' -Accent $script:Colors.Green
}

function Toggle-TodayPause {
    if (Test-TodayPauseActive) {
        Clear-TodayPause
        return
    }

    Set-TodayPause
}

function Test-FocusShouldDelay {
    param(
        [datetime]$Now,
        [datetime]$DueAt
    )

    if (-not (Test-FocusDoNotDisturbActive)) {
        return $false
    }

    if ($Now -ge $DueAt.AddMinutes((Get-FocusMaxDelayMinutes))) {
        return $false
    }

    return ((Get-UserIdleSeconds) -lt (Get-FocusIdleSeconds))
}

function Test-ReminderReady {
    param(
        [datetime]$Now,
        [datetime]$DueAt,
        [string]$LastFiredDate
    )

    if ($LastFiredDate -eq $Now.ToString('yyyy-MM-dd')) {
        return $false
    }

    if ($Now -lt $DueAt) {
        return $false
    }

    $windowMinutes = if (Test-FocusDoNotDisturbActive) {
        Get-FocusMaxDelayMinutes
    }
    else {
        5
    }

    if ($Now -gt $DueAt.AddMinutes($windowMinutes).AddMinutes(5)) {
        return $false
    }

    if (Test-FocusShouldDelay -Now $Now -DueAt $DueAt) {
        return $false
    }

    return $true
}

function Show-FocusDoNotDisturbDialog {
    param([System.Windows.Forms.Form]$OwnerForm)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '专注勿扰'
    Set-FormThemeIdentity -Form $dialog -Suffix '专注勿扰'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.TopMost = $true
    $dialog.BackColor = $script:Colors.Surface
    $dialog.ClientSize = New-Object System.Drawing.Size(430, 220)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '专注勿扰'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(24, 24)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $false
    $hint.Text = '提醒到点后，如果你正在动键盘或鼠标，会先不弹窗；检测到键盘和鼠标都静止 60 秒后再弹。'
    $hint.Location = New-Object System.Drawing.Point(26, 62)
    $hint.Size = New-Object System.Drawing.Size(372, 46)
    $hint.ForeColor = $script:Colors.Muted
    $dialog.Controls.Add($hint)

    $delayLabel = New-Object System.Windows.Forms.Label
    $delayLabel.Text = '最多延迟'
    $delayLabel.AutoSize = $true
    $delayLabel.Location = New-Object System.Drawing.Point(28, 128)
    $delayLabel.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($delayLabel)

    $delayBox = New-Object System.Windows.Forms.NumericUpDown
    $delayBox.Minimum = 1
    $delayBox.Maximum = 120
    $delayBox.Value = Get-FocusMaxDelayMinutes
    $delayBox.Location = New-Object System.Drawing.Point(112, 124)
    $delayBox.Size = New-Object System.Drawing.Size(80, 28)
    $delayBox.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
    $dialog.Controls.Add($delayBox)

    $minuteLabel = New-Object System.Windows.Forms.Label
    $minuteLabel.Text = '分钟后强制弹出'
    $minuteLabel.AutoSize = $true
    $minuteLabel.Location = New-Object System.Drawing.Point(204, 128)
    $minuteLabel.ForeColor = $script:Colors.Muted
    $dialog.Controls.Add($minuteLabel)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '保存'
    $ok.Size = New-Object System.Drawing.Size(96, 36)
    $ok.Location = New-Object System.Drawing.Point(206, 170)
    $ok.BackColor = $script:Colors.Blue
    $ok.ForeColor = [System.Drawing.Color]::White
    $ok.FlatStyle = 'Flat'
    $ok.FlatAppearance.BorderSize = 0
    $dialog.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Size = New-Object System.Drawing.Size(96, 36)
    $cancel.Location = New-Object System.Drawing.Point(310, 170)
    $cancel.BackColor = $script:Colors.Surface
    $cancel.ForeColor = $script:Colors.Text
    $cancel.FlatStyle = 'Flat'
    $cancel.FlatAppearance.BorderColor = $script:Colors.Border
    $cancel.FlatAppearance.BorderSize = 1
    $dialog.Controls.Add($cancel)

    $ok.Add_Click({
        param($sender, $e)
        $sender.FindForm().Tag = [int]$delayBox.Value
        $sender.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK
        $sender.FindForm().Close()
    })

    $cancel.Add_Click({
        param($sender, $e)
        $sender.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $sender.FindForm().Close()
    })

    $dialog.Add_Shown({
        param($sender, $e)
        Enable-WindowGlass -Form $sender
        Start-FormFadeIn -Form $sender -TargetOpacity 0.98
    })

    $result = $dialog.ShowDialog($OwnerForm)
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return [int]$dialog.Tag
}

function Show-WorkScheduleDialog {
    param([System.Windows.Forms.Form]$OwnerForm)

    $work = Get-WorkSchedule
    $mode = Get-WorkScheduleMode -Value $work.Mode

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '工作制'
    Set-FormThemeIdentity -Form $dialog -Suffix '工作制'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.TopMost = $true
    $dialog.BackColor = $script:Colors.Surface
    $dialog.ClientSize = New-Object System.Drawing.Size(460, 360)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '工作制'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(24, 24)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $false
    $hint.Text = '工作制会影响本周吃饭打卡统计的应统计日期。'
    $hint.Location = New-Object System.Drawing.Point(26, 60)
    $hint.Size = New-Object System.Drawing.Size(404, 24)
    $hint.ForeColor = $script:Colors.Muted
    $dialog.Controls.Add($hint)

    $doubleRest = New-Object System.Windows.Forms.RadioButton
    $doubleRest.Text = '双休'
    $doubleRest.AutoSize = $true
    $doubleRest.Location = New-Object System.Drawing.Point(30, 100)
    $doubleRest.BackColor = $script:Colors.Surface
    $doubleRest.ForeColor = $script:Colors.Text
    $doubleRest.Checked = ($mode -eq 'DoubleRest')
    $dialog.Controls.Add($doubleRest)

    $singleRest = New-Object System.Windows.Forms.RadioButton
    $singleRest.Text = '单休'
    $singleRest.AutoSize = $true
    $singleRest.Location = New-Object System.Drawing.Point(30, 140)
    $singleRest.BackColor = $script:Colors.Surface
    $singleRest.ForeColor = $script:Colors.Text
    $singleRest.Checked = ($mode -eq 'SingleRest')
    $dialog.Controls.Add($singleRest)

    $singlePanel = New-Object System.Windows.Forms.Panel
    $singlePanel.Location = New-Object System.Drawing.Point(126, 132)
    $singlePanel.Size = New-Object System.Drawing.Size(210, 34)
    $singlePanel.BackColor = $script:Colors.Surface
    $dialog.Controls.Add($singlePanel)

    $singleSaturday = New-Object System.Windows.Forms.RadioButton
    $singleSaturday.Text = '周六休'
    $singleSaturday.AutoSize = $true
    $singleSaturday.Location = New-Object System.Drawing.Point(0, 6)
    $singleSaturday.BackColor = $script:Colors.Surface
    $singleSaturday.ForeColor = $script:Colors.Text
    $singleSaturday.Checked = ((Get-WeekendDay -Value $work.SingleRestDay -Default 'Sunday') -eq 'Saturday')
    $singlePanel.Controls.Add($singleSaturday)

    $singleSunday = New-Object System.Windows.Forms.RadioButton
    $singleSunday.Text = '周日休'
    $singleSunday.AutoSize = $true
    $singleSunday.Location = New-Object System.Drawing.Point(90, 6)
    $singleSunday.BackColor = $script:Colors.Surface
    $singleSunday.ForeColor = $script:Colors.Text
    $singleSunday.Checked = (-not $singleSaturday.Checked)
    $singlePanel.Controls.Add($singleSunday)

    $bigSmall = New-Object System.Windows.Forms.RadioButton
    $bigSmall.Text = '大小周'
    $bigSmall.AutoSize = $true
    $bigSmall.Location = New-Object System.Drawing.Point(30, 184)
    $bigSmall.BackColor = $script:Colors.Surface
    $bigSmall.ForeColor = $script:Colors.Text
    $bigSmall.Checked = ($mode -eq 'BigSmall')
    $dialog.Controls.Add($bigSmall)

    $bigPanel = New-Object System.Windows.Forms.Panel
    $bigPanel.Location = New-Object System.Drawing.Point(126, 176)
    $bigPanel.Size = New-Object System.Drawing.Size(300, 34)
    $bigPanel.BackColor = $script:Colors.Surface
    $dialog.Controls.Add($bigPanel)

    $bigSaturday = New-Object System.Windows.Forms.RadioButton
    $bigSaturday.Text = '小周周六上班'
    $bigSaturday.AutoSize = $true
    $bigSaturday.Location = New-Object System.Drawing.Point(0, 6)
    $bigSaturday.BackColor = $script:Colors.Surface
    $bigSaturday.ForeColor = $script:Colors.Text
    $bigSaturday.Checked = ((Get-WeekendDay -Value $work.BigSmallWorkDay -Default 'Saturday') -eq 'Saturday')
    $bigPanel.Controls.Add($bigSaturday)

    $bigSunday = New-Object System.Windows.Forms.RadioButton
    $bigSunday.Text = '小周周日上班'
    $bigSunday.AutoSize = $true
    $bigSunday.Location = New-Object System.Drawing.Point(130, 6)
    $bigSunday.BackColor = $script:Colors.Surface
    $bigSunday.ForeColor = $script:Colors.Text
    $bigSunday.Checked = (-not $bigSaturday.Checked)
    $bigPanel.Controls.Add($bigSunday)

    $preview = New-Object System.Windows.Forms.Label
    $preview.AutoSize = $false
    $preview.Location = New-Object System.Drawing.Point(28, 236)
    $preview.Size = New-Object System.Drawing.Size(400, 34)
    $preview.ForeColor = $script:Colors.Muted
    $dialog.Controls.Add($preview)

    $updatePreview = {
        if ($doubleRest.Checked) {
            $preview.Text = '当前选择：周一到周五统计，周六周日不统计。'
        }
        elseif ($singleRest.Checked) {
            $restText = if ($singleSaturday.Checked) { '周六' } else { '周日' }
            $preview.Text = ('当前选择：{0}休，另一个周末日计入统计。' -f $restText)
        }
        else {
            $workText = if ($bigSunday.Checked) { '周日' } else { '周六' }
            $preview.Text = ('当前选择：小周{0}上班，大周周末不统计。' -f $workText)
        }
    }

    foreach ($control in @($doubleRest, $singleRest, $singleSaturday, $singleSunday, $bigSmall, $bigSaturday, $bigSunday)) {
        $control.Add_CheckedChanged({ & $updatePreview })
    }
    $singleSaturday.Add_CheckedChanged({
        if ($singleSaturday.Checked) {
            $singleRest.Checked = $true
        }
    })
    $singleSaturday.Add_Click({ $singleRest.Checked = $true })
    $singleSunday.Add_CheckedChanged({
        if ($singleSunday.Checked) {
            $singleRest.Checked = $true
        }
    })
    $singleSunday.Add_Click({ $singleRest.Checked = $true })
    $bigSaturday.Add_CheckedChanged({
        if ($bigSaturday.Checked) {
            $bigSmall.Checked = $true
        }
    })
    $bigSaturday.Add_Click({ $bigSmall.Checked = $true })
    $bigSunday.Add_CheckedChanged({
        if ($bigSunday.Checked) {
            $bigSmall.Checked = $true
        }
    })
    $bigSunday.Add_Click({ $bigSmall.Checked = $true })
    & $updatePreview

    $saveBtn = New-Object System.Windows.Forms.Button
    $saveBtn.Text = '保存'
    $saveBtn.Size = New-Object System.Drawing.Size(96, 36)
    $saveBtn.Location = New-Object System.Drawing.Point(248, 304)
    $saveBtn.BackColor = $script:Colors.Blue
    $saveBtn.ForeColor = [System.Drawing.Color]::White
    $saveBtn.FlatStyle = 'Flat'
    $saveBtn.FlatAppearance.BorderSize = 0
    $dialog.Controls.Add($saveBtn)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Size = New-Object System.Drawing.Size(96, 36)
    $cancel.Location = New-Object System.Drawing.Point(352, 304)
    $cancel.BackColor = $script:Colors.Surface
    $cancel.ForeColor = $script:Colors.Text
    $cancel.FlatStyle = 'Flat'
    $cancel.FlatAppearance.BorderColor = $script:Colors.Border
    $cancel.FlatAppearance.BorderSize = 1
    $dialog.Controls.Add($cancel)

    $saveBtn.Add_Click({
        param($sender, $e)

        if ($doubleRest.Checked) {
            $script:Config.Preferences.WorkSchedule.Mode = 'DoubleRest'
        }
        elseif ($singleRest.Checked) {
            $script:Config.Preferences.WorkSchedule.Mode = 'SingleRest'
            $script:Config.Preferences.WorkSchedule.SingleRestDay = if ($singleSaturday.Checked) { 'Saturday' } else { 'Sunday' }
        }
        else {
            $script:Config.Preferences.WorkSchedule.Mode = 'BigSmall'
            $script:Config.Preferences.WorkSchedule.BigSmallWorkDay = if ($bigSunday.Checked) { 'Sunday' } else { 'Saturday' }
            if ([string]::IsNullOrWhiteSpace([string]$script:Config.Preferences.WorkSchedule.BigSmallAnchorMonday)) {
                $script:Config.Preferences.WorkSchedule.BigSmallAnchorMonday = (Get-WeekMonday -Date (Get-Date)).ToString('yyyy-MM-dd')
            }
        }

        Save-Config
        Update-MainStatus
        Update-TrayStats
        Write-AppLog -Event 'WorkScheduleSaved' -Message (Get-WorkScheduleText)
        Show-Toast -Message (Get-WorkScheduleText) -Accent $script:Colors.Green
        $sender.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::OK
        $sender.FindForm().Close()
    })

    $cancel.Add_Click({
        param($sender, $e)
        $sender.FindForm().DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $sender.FindForm().Close()
    })

    $dialog.Add_Shown({
        param($sender, $e)
        Enable-WindowGlass -Form $sender
        Start-FormFadeIn -Form $sender -TargetOpacity 0.98
    })

    [void]$dialog.ShowDialog($OwnerForm)
}

function Play-ReminderSound {
    param([bool]$Strong = $false)

    try {
        if ($Strong) {
            [System.Media.SystemSounds]::Exclamation.Play()
            Start-Sleep -Milliseconds 180
            [System.Media.SystemSounds]::Exclamation.Play()
            return
        }

        [System.Media.SystemSounds]::Asterisk.Play()
    }
    catch {
        Write-AppLog -Event 'SoundFailed' -Message $_.Exception.Message -Level 'WARN'
    }
}

function Show-CustomRemindersDialog {
    param([System.Windows.Forms.Form]$OwnerForm)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '自定义提醒'
    Set-FormThemeIdentity -Form $dialog -Suffix '自定义提醒'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(680, 520)
    $dialog.BackColor = $script:Colors.Background
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $dialog.Opacity = 0

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '自定义提醒'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(24, 18)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($title)

    $list = New-Object System.Windows.Forms.ListBox
    $list.Location = New-Object System.Drawing.Point(24, 58)
    $list.Size = New-Object System.Drawing.Size(292, 346)
    $list.BackColor = $script:Colors.Surface
    $list.ForeColor = $script:Colors.Text
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $dialog.Controls.Add($list)

    $enabled = New-Object System.Windows.Forms.CheckBox
    $enabled.Text = '启用'
    $enabled.Checked = $true
    $enabled.Location = New-Object System.Drawing.Point(346, 58)
    $enabled.Size = New-Object System.Drawing.Size(86, 24)
    $enabled.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($enabled)

    $sound = New-Object System.Windows.Forms.CheckBox
    $sound.Text = '播放声音'
    $sound.Checked = $true
    $sound.Location = New-Object System.Drawing.Point(438, 58)
    $sound.Size = New-Object System.Drawing.Size(104, 24)
    $sound.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($sound)

    $strong = New-Object System.Windows.Forms.CheckBox
    $strong.Text = '强提醒'
    $strong.Checked = $false
    $strong.Location = New-Object System.Drawing.Point(548, 58)
    $strong.Size = New-Object System.Drawing.Size(94, 24)
    $strong.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($strong)

    $timeLabel = New-Object System.Windows.Forms.Label
    $timeLabel.Text = '时间'
    $timeLabel.AutoSize = $true
    $timeLabel.Location = New-Object System.Drawing.Point(346, 100)
    $timeLabel.ForeColor = $script:Colors.Muted
    $dialog.Controls.Add($timeLabel)

    $hour = New-Object System.Windows.Forms.NumericUpDown
    $hour.Minimum = 0
    $hour.Maximum = 23
    $hour.Value = 9
    $hour.Location = New-Object System.Drawing.Point(346, 126)
    $hour.Size = New-Object System.Drawing.Size(70, 26)
    $dialog.Controls.Add($hour)

    $minute = New-Object System.Windows.Forms.NumericUpDown
    $minute.Minimum = 0
    $minute.Maximum = 59
    $minute.Value = 0
    $minute.Location = New-Object System.Drawing.Point(426, 126)
    $minute.Size = New-Object System.Drawing.Size(70, 26)
    $dialog.Controls.Add($minute)

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = '标题'
    $nameLabel.AutoSize = $true
    $nameLabel.Location = New-Object System.Drawing.Point(346, 174)
    $nameLabel.ForeColor = $script:Colors.Muted
    $dialog.Controls.Add($nameLabel)

    $nameBox = New-Object System.Windows.Forms.TextBox
    $nameBox.Location = New-Object System.Drawing.Point(346, 200)
    $nameBox.Size = New-Object System.Drawing.Size(298, 26)
    $nameBox.Text = '自定义提醒'
    $dialog.Controls.Add($nameBox)

    $messageLabel = New-Object System.Windows.Forms.Label
    $messageLabel.Text = '提醒内容'
    $messageLabel.AutoSize = $true
    $messageLabel.Location = New-Object System.Drawing.Point(346, 246)
    $messageLabel.ForeColor = $script:Colors.Muted
    $dialog.Controls.Add($messageLabel)

    $messageBox = New-Object System.Windows.Forms.TextBox
    $messageBox.Location = New-Object System.Drawing.Point(346, 272)
    $messageBox.Size = New-Object System.Drawing.Size(298, 92)
    $messageBox.Multiline = $true
    $messageBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $messageBox.Text = '你设置的自定义提醒时间到了。'
    $dialog.Controls.Add($messageBox)

    $error = New-Object System.Windows.Forms.Label
    $error.AutoSize = $false
    $error.Text = ''
    $error.Location = New-Object System.Drawing.Point(24, 420)
    $error.Size = New-Object System.Drawing.Size(620, 22)
    $error.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
    $dialog.Controls.Add($error)

    $newBtn = New-Object System.Windows.Forms.Button
    $newBtn.Text = '新增'
    $newBtn.Size = New-Object System.Drawing.Size(92, 36)
    $newBtn.Location = New-Object System.Drawing.Point(24, 456)
    $newBtn.BackColor = $script:Colors.Green
    $newBtn.ForeColor = [System.Drawing.Color]::White
    $newBtn.FlatStyle = 'Flat'
    $newBtn.FlatAppearance.BorderSize = 0
    $dialog.Controls.Add($newBtn)

    $saveBtn = New-Object System.Windows.Forms.Button
    $saveBtn.Text = '保存'
    $saveBtn.Size = New-Object System.Drawing.Size(92, 36)
    $saveBtn.Location = New-Object System.Drawing.Point(446, 456)
    $saveBtn.BackColor = $script:Colors.Blue
    $saveBtn.ForeColor = [System.Drawing.Color]::White
    $saveBtn.FlatStyle = 'Flat'
    $saveBtn.FlatAppearance.BorderSize = 0
    $dialog.Controls.Add($saveBtn)

    $deleteBtn = New-Object System.Windows.Forms.Button
    $deleteBtn.Text = '删除'
    $deleteBtn.Size = New-Object System.Drawing.Size(92, 36)
    $deleteBtn.Location = New-Object System.Drawing.Point(124, 456)
    $deleteBtn.BackColor = $script:Colors.OrangeSoft
    $deleteBtn.ForeColor = $script:Colors.Orange
    $deleteBtn.FlatStyle = 'Flat'
    $deleteBtn.FlatAppearance.BorderColor = $script:Colors.Border
    $deleteBtn.FlatAppearance.BorderSize = 1
    $dialog.Controls.Add($deleteBtn)

    $closeBtn = New-Object System.Windows.Forms.Button
    $closeBtn.Text = '关闭'
    $closeBtn.Size = New-Object System.Drawing.Size(92, 36)
    $closeBtn.Location = New-Object System.Drawing.Point(552, 456)
    $closeBtn.BackColor = $script:Colors.Surface
    $closeBtn.ForeColor = $script:Colors.Text
    $closeBtn.FlatStyle = 'Flat'
    $closeBtn.FlatAppearance.BorderColor = $script:Colors.Border
    $closeBtn.FlatAppearance.BorderSize = 1
    $dialog.Controls.Add($closeBtn)

    $refreshList = {
        $selectedId = $null
        $itemsBefore = Get-CustomReminderList
        if ($list.SelectedIndex -ge 0 -and $list.SelectedIndex -lt @($itemsBefore).Count) {
            $selectedId = @($itemsBefore)[$list.SelectedIndex].Id
        }

        $list.Items.Clear()
        foreach ($item in (Get-CustomReminderList)) {
            [void]$list.Items.Add((Get-CustomReminderDisplayText -Item $item))
        }

        if ($selectedId) {
            $itemsAfter = Get-CustomReminderList
            for ($i = 0; $i -lt @($itemsAfter).Count; $i++) {
                if (@($itemsAfter)[$i].Id -eq $selectedId) {
                    $list.SelectedIndex = $i
                    break
                }
            }
        }
    }

    $loadSelected = {
        $items = Get-CustomReminderList
        if ($list.SelectedIndex -lt 0 -or $list.SelectedIndex -ge @($items).Count) {
            return
        }

        $item = @($items)[$list.SelectedIndex]
        $parts = Get-DailyReminderTimeParts -TimeText $item.Time -DefaultHour 9 -DefaultMinute 0
        $hour.Value = $parts.Hour
        $minute.Value = $parts.Minute
        $nameBox.Text = [string]$item.Title
        $messageBox.Text = [string]$item.Message
        $enabled.Checked = [bool]$item.Enabled
        $strong.Checked = [bool]$item.Strong
        $sound.Checked = [bool]$item.Sound
        $error.Text = ''
    }

    $list.Add_SelectedIndexChanged({ & $loadSelected })

    $newBtn.Add_Click({
        $list.ClearSelected()
        $hour.Value = 9
        $minute.Value = 0
        $nameBox.Text = '自定义提醒'
        $messageBox.Text = '你设置的自定义提醒时间到了。'
        $enabled.Checked = $true
        $sound.Checked = $true
        $strong.Checked = $false
        $error.Text = ''
        $nameBox.Focus()
        $nameBox.SelectAll()
    })

    $saveBtn.Add_Click({
        $titleText = $nameBox.Text.Trim()
        $messageText = $messageBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($titleText)) {
            $error.Text = '标题不能为空。'
            return
        }
        if ([string]::IsNullOrWhiteSpace($messageText)) {
            $messageText = '你设置的自定义提醒时间到了。'
        }

        $timeText = Format-ReminderTime -Hour ([int]$hour.Value) -Minute ([int]$minute.Value)
        $items = Get-CustomReminderList
        if ($list.SelectedIndex -ge 0 -and $list.SelectedIndex -lt @($items).Count) {
            $item = @($items)[$list.SelectedIndex]
            $changed = ([string]$item.Time -ne $timeText) -or ([string]$item.Title -ne $titleText)
            $item.Enabled = [bool]$enabled.Checked
            $item.Time = $timeText
            $item.Title = $titleText
            $item.Message = $messageText
            $item.Strong = [bool]$strong.Checked
            $item.Sound = [bool]$sound.Checked
            if ($changed) {
                $item.LastFiredDate = $null
            }
            $script:Config.CustomReminders = @($items)
        }
        else {
            $newItem = New-CustomReminder -TimeText $timeText -Title $titleText -Message $messageText -Enabled ([bool]$enabled.Checked) -Strong ([bool]$strong.Checked) -Sound ([bool]$sound.Checked)
            $script:Config.CustomReminders = @($items) + $newItem
        }

        Save-Config
        Update-MainStatus
        Write-AppLog -Event 'CustomReminderSaved' -Message (Get-NextCustomText)
        & $refreshList
        Show-Toast -Message '自定义提醒已保存' -Accent $script:Colors.Green
    })

    $deleteBtn.Add_Click({
        $items = Get-CustomReminderList
        if ($list.SelectedIndex -lt 0 -or $list.SelectedIndex -ge @($items).Count) {
            $error.Text = '先选中一个提醒再删除。'
            return
        }

        $removeId = @($items)[$list.SelectedIndex].Id
        $script:Config.CustomReminders = @($items | Where-Object { $_.Id -ne $removeId })
        Save-Config
        Update-MainStatus
        Write-AppLog -Event 'CustomReminderDeleted' -Message ('Id={0}' -f $removeId)
        $list.ClearSelected()
        & $refreshList
    })

    $closeBtn.Add_Click({
        $dialog.Close()
    })

    $dialog.Add_Shown({
        param($sender, $e)
        & $refreshList
        Enable-WindowGlass -Form $sender
        Start-FormFadeIn -Form $sender -TargetOpacity 0.98
    })

    [void]$dialog.ShowDialog($OwnerForm)
}

function Set-GradientPanel {
    param(
        [System.Windows.Forms.Control]$Control,
        [System.Drawing.Color]$LeftColor,
        [System.Drawing.Color]$RightColor
    )

    if ($null -eq $Control) {
        return
    }

    $Control.BackColor = $LeftColor
    $Control.Invalidate()
}

function Show-Toast {
    param(
        [string]$Message,
        [System.Drawing.Color]$Accent = $script:Colors.Green
    )

    $toast = New-Object System.Windows.Forms.Form
    $toast.StartPosition = 'CenterScreen'
    $toast.FormBorderStyle = 'FixedToolWindow'
    $toast.ShowInTaskbar = $false
    $toast.TopMost = $true
    $toast.BackColor = $script:Colors.Surface
    $toast.ClientSize = New-Object System.Drawing.Size(360, 128)
    $toast.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $edge = New-Object System.Windows.Forms.Panel
    $edge.Dock = 'Fill'
    $edge.BackColor = $script:Colors.Surface
    $edge.Padding = New-Object System.Windows.Forms.Padding(18, 18, 18, 16)
    $toast.Controls.Add($edge)

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'
    $top.Height = 8
    $edge.Controls.Add($top)
    Set-GradientPanel -Control $top -LeftColor $Accent -RightColor $script:Colors.Purple

    $label = New-Object System.Windows.Forms.Label
    $label.Dock = 'Fill'
    $label.Text = $Message
    $label.ForeColor = $script:Colors.Text
    $label.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
    $label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $label.Padding = New-Object System.Windows.Forms.Padding(8, 10, 8, 8)
    $edge.Controls.Add($label)

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1500
    $toast.Tag = $timer
    $timer.Tag = $toast
    $timer.Add_Tick({
        param($sender, $e)
        $sender.Stop()
        $sender.Tag.Close()
    })

    $toast.Add_Shown({
        param($sender, $e)
        Enable-WindowGlass -Form $sender
        Start-FormFadeIn -Form $sender -TargetOpacity 0.96
        $sender.Tag.Start()
    })

    [void]$toast.Show()
}

function Update-MainStatus {
    if ($null -eq $script:MainForm -or $script:MainForm.IsDisposed) {
        return
    }

    $mode = Get-ModeLabel
    $singleMode = Get-SingleReminderScheduleMode -Value $script:Config.SingleReminder.ScheduleMode
    $singleModeText = if ($singleMode -eq 'ClockTime') { '单次：固定时刻' } else { '单次：按当前时间顺延' }
    $script:StatusLabel.Text = "当前模式：$mode"
    $script:DetailLabel.Text = ('{0} | 单次：{1} | {2} | {3} | {4} | {5}' -f $singleModeText, (Get-SingleReminderText), (Get-NextCustomText), (Get-FocusDoNotDisturbText), (Get-TodayPauseText), (Get-WorkScheduleText))
    Update-DailyReminderRows

    if ($script:MainThemeControls -and $script:MainThemeControls.PSObject.Properties.Name -contains 'BtnPauseToday' -and $script:MainThemeControls.BtnPauseToday) {
        $script:MainThemeControls.BtnPauseToday.Text = if (Test-TodayPauseActive) { '恢复今日' } else { '今日暂停' }
    }

    if ($script:TrayIcon) {
        $script:TrayIcon.Text = Get-ThemeWindowTitle -Theme $script:Config.Preferences.Theme
        $script:TrayIcon.Icon = Get-ThemeIcon -Theme $script:Config.Preferences.Theme
    }

    if ($script:TrayPauseTodayItem) {
        $script:TrayPauseTodayItem.Text = if (Test-TodayPauseActive) { '恢复今日提醒' } else { '今日暂停提醒' }
    }
}

function Update-ClockDisplay {
    if ($null -eq $script:MainForm -or $script:MainForm.IsDisposed) {
        return
    }

    $now = [datetime]::Now
    if ($script:ClockLabel) {
        $script:ClockLabel.Text = $now.ToString('HH:mm:ss')
    }
    if ($script:ClockDateLabel) {
        $script:ClockDateLabel.Text = $now.ToString('yyyy-MM-dd dddd')
    }
}

function Set-Mode {
    param([ValidateSet('Company', 'Trip')]$Mode)

    $script:Config.Mode = $Mode
    Save-Config
    Update-MainStatus
    Apply-MainTheme
    Write-AppLog -Event 'ModeChanged' -Message ('当前模式：{0}' -f (Get-ModeLabel))

    if ($Mode -eq 'Trip') {
        Show-Toast -Message '已切换到出差中，所有提醒暂时屏蔽' -Accent $script:Colors.Orange
    }
    else {
        Show-Toast -Message '已切换到公司上班，未单独屏蔽的提醒会开启' -Accent $script:Colors.Blue
    }
}

function Show-MainWindow {
    if ($null -eq $script:MainForm -or $script:MainForm.IsDisposed) {
        return
    }

    if ($script:MainForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    }

    $script:MainForm.Show()
    Enable-WindowGlass -Form $script:MainForm
    $script:MainForm.Activate()
}

function Get-NextDailyCandidateText {
    param([string]$Name)

    $item = $script:Config.DailyReminders.$Name
    if (-not [bool]$item.Enabled) {
        return '未开启'
    }

    if ($script:Config.Mode -eq 'Trip') {
        return '出差中，暂不触发'
    }

    try {
        $candidate = Get-ScheduledDateTime -TimeText $item.Time
        if ($candidate -le [datetime]::Now -or $item.LastFiredDate -eq ([datetime]::Now.ToString('yyyy-MM-dd'))) {
            $candidate = $candidate.AddDays(1)
        }
        return $candidate.ToString('yyyy-MM-dd HH:mm')
    }
    catch {
        return '时间格式异常'
    }
}

function Show-SingleReminderDialog {
    param([System.Windows.Forms.Form]$OwnerForm)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '设置下次单次提醒时间'
    Set-FormThemeIdentity -Form $dialog -Suffix '设置下次单次提醒时间'
    $dialog.StartPosition = 'CenterScreen'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.TopMost = $true
    $dialog.BackColor = $script:Colors.Surface
    $dialog.ClientSize = New-Object System.Drawing.Size(480, 308)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 8
    $dialog.Controls.Add($header)
    Set-GradientPanel -Control $header -LeftColor $script:Colors.Blue -RightColor $script:Colors.Purple

    $title = New-Object System.Windows.Forms.Label
    $title.AutoSize = $false
    $title.Text = '请选择下次单次提醒时间'
    $title.Location = New-Object System.Drawing.Point(24, 24)
    $title.Size = New-Object System.Drawing.Size(380, 32)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($title)

    $hint = New-Object System.Windows.Forms.Label
    $hint.AutoSize = $false
    $hint.Text = '顺延模式下 0时1分 表示 1 分钟后；固定时刻模式下按当天时刻计算。'
    $hint.Location = New-Object System.Drawing.Point(24, 58)
    $hint.Size = New-Object System.Drawing.Size(380, 24)
    $hint.ForeColor = $script:Colors.Muted
    $dialog.Controls.Add($hint)

    $modeLabel = New-Object System.Windows.Forms.Label
    $modeLabel.AutoSize = $true
    $modeLabel.Text = '计算方式'
    $modeLabel.Location = New-Object System.Drawing.Point(24, 92)
    $modeLabel.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($modeLabel)

    $modeBox = New-Object System.Windows.Forms.ComboBox
    $modeBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $modeBox.Location = New-Object System.Drawing.Point(102, 88)
    $modeBox.Size = New-Object System.Drawing.Size(180, 30)
    [void]$modeBox.Items.Add('按当前时间顺延')
    [void]$modeBox.Items.Add('按固定时刻')
    $modeBox.SelectedIndex = if ((Get-SingleReminderScheduleMode -Value $script:Config.SingleReminder.ScheduleMode) -eq 'ClockTime') { 1 } else { 0 }
    $dialog.Controls.Add($modeBox)

    $hourLabel = New-Object System.Windows.Forms.Label
    $hourLabel.AutoSize = $true
    $hourLabel.Text = '小时'
    $hourLabel.Location = New-Object System.Drawing.Point(24, 132)
    $hourLabel.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($hourLabel)

    $hourBox = New-Object System.Windows.Forms.NumericUpDown
    $hourBox.Location = New-Object System.Drawing.Point(74, 128)
    $hourBox.Size = New-Object System.Drawing.Size(90, 30)
    $hourBox.Minimum = 0
    $hourBox.Maximum = 23
    $hourBox.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
    $hourBox.Value = [datetime]::Now.Hour
    $dialog.Controls.Add($hourBox)

    $minuteLabel = New-Object System.Windows.Forms.Label
    $minuteLabel.AutoSize = $true
    $minuteLabel.Text = '分钟'
    $minuteLabel.Location = New-Object System.Drawing.Point(184, 132)
    $minuteLabel.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($minuteLabel)

    $minuteBox = New-Object System.Windows.Forms.NumericUpDown
    $minuteBox.Location = New-Object System.Drawing.Point(234, 128)
    $minuteBox.Size = New-Object System.Drawing.Size(90, 30)
    $minuteBox.Minimum = 0
    $minuteBox.Maximum = 59
    $minuteBox.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
    $minuteBox.Value = [datetime]::Now.Minute
    $dialog.Controls.Add($minuteBox)

    if ($modeBox.SelectedIndex -eq 0) {
        $hourBox.Value = 0
        $minuteBox.Value = 1
        $hourLabel.Text = '延后小时'
        $minuteLabel.Text = '延后分钟'
    }

    $note = New-Object System.Windows.Forms.Label
    $note.AutoSize = $false
    $note.Text = '顺延模式下表示延后多久；固定时刻模式下表示几点几分。'
    $note.Location = New-Object System.Drawing.Point(24, 164)
    $note.Size = New-Object System.Drawing.Size(320, 22)
    $note.ForeColor = $script:Colors.Muted
    $dialog.Controls.Add($note)

    $preview = New-Object System.Windows.Forms.Label
    $preview.AutoSize = $false
    $preview.Location = New-Object System.Drawing.Point(24, 188)
    $preview.Size = New-Object System.Drawing.Size(420, 24)
    $preview.ForeColor = $script:Colors.Blue
    $dialog.Controls.Add($preview)

    $error = New-Object System.Windows.Forms.Label
    $error.AutoSize = $false
    $error.Text = ''
    $error.Location = New-Object System.Drawing.Point(24, 214)
    $error.Size = New-Object System.Drawing.Size(420, 24)
    $error.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
    $dialog.Controls.Add($error)

    $setBtn = New-Object System.Windows.Forms.Button
    $setBtn.Text = '设置'
    $setBtn.Size = New-Object System.Drawing.Size(110, 38)
    $setBtn.Location = New-Object System.Drawing.Point(248, 238)
    $setBtn.BackColor = $script:Colors.Blue
    $setBtn.ForeColor = [System.Drawing.Color]::White
    $setBtn.FlatStyle = 'Flat'
    $setBtn.FlatAppearance.BorderSize = 0
    $dialog.Controls.Add($setBtn)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Size = New-Object System.Drawing.Size(110, 38)
    $cancel.Location = New-Object System.Drawing.Point(364, 238)
    $cancel.BackColor = $script:Colors.Surface
    $cancel.ForeColor = $script:Colors.Text
    $cancel.FlatStyle = 'Flat'
    $cancel.FlatAppearance.BorderColor = $script:Colors.Border
    $cancel.FlatAppearance.BorderSize = 1
    $dialog.Controls.Add($cancel)

    $updatePreview = {
        $now = [datetime]::Now
        $scheduleMode = if ($modeBox.SelectedIndex -eq 1) { 'ClockTime' } else { 'Relative' }
        $candidate = Get-SingleReminderCandidate -Hour ([int]$hourBox.Value) -Minute ([int]$minuteBox.Value) -ScheduleMode $scheduleMode -BaseNow $now
        $preview.Text = '预览：' + (Format-SingleReminderDisplay -At $candidate)
    }

    $modeBox.Add_SelectedIndexChanged({
        param($sender, $e)
        if ($sender.SelectedIndex -eq 0) {
            $hourLabel.Text = '延后小时'
            $minuteLabel.Text = '延后分钟'
            $hourBox.Value = 0
            $minuteBox.Value = 1
        }
        else {
            $hourLabel.Text = '小时'
            $minuteLabel.Text = '分钟'
            $hourBox.Value = [datetime]::Now.Hour
            $minuteBox.Value = [datetime]::Now.Minute
        }
        & $updatePreview
    })

    $hourBox.Add_ValueChanged({
        param($sender, $e)
        & $updatePreview
    })

    $minuteBox.Add_ValueChanged({
        param($sender, $e)
        & $updatePreview
    })

    $setBtn.Add_Click({
        param($sender, $e)
        $h = [int]$hourBox.Value
        $m = [int]$minuteBox.Value
        $now = [datetime]::Now
        $scheduleMode = if ($modeBox.SelectedIndex -eq 1) { 'ClockTime' } else { 'Relative' }
        $candidate = Get-SingleReminderCandidate -Hour $h -Minute $m -ScheduleMode $scheduleMode -BaseNow $now

        $script:Config.SingleReminder.Enabled = $true
        $script:Config.SingleReminder.At = $candidate.ToString('o')
        $script:Config.SingleReminder.Triggered = $false
        $script:Config.SingleReminder.ScheduleMode = $scheduleMode
        Save-Config
        Write-AppLog -Event 'SingleReminderSet' -Message ('单次提醒设置为 {0}' -f (Format-SingleReminderDisplay -At $candidate))
        $dialog.Tag = $candidate
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $dialog.Add_Shown({
        param($sender, $e)
        Enable-WindowGlass -Form $sender
        Start-FormFadeIn -Form $sender -TargetOpacity 0.98
        & $updatePreview
    })

    $cancel.Add_Click({
        param($sender, $e)
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    $result = $dialog.ShowDialog($OwnerForm)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        $when = [datetime]$dialog.Tag
        Show-Toast -Message ('设置成功：{0}' -f (Format-SingleReminderDisplay -At $when)) -Accent $script:Colors.Green
        Update-MainStatus
    }
}

function Show-SettingsDialog {
    param([System.Windows.Forms.Form]$OwnerForm)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '设置'
    Set-FormThemeIdentity -Form $dialog -Suffix '设置'
    $dialog.StartPosition = 'CenterScreen'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.TopMost = $true
    $dialog.BackColor = $script:Colors.Surface
    $dialog.ClientSize = New-Object System.Drawing.Size(500, 510)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 8
    $dialog.Controls.Add($header)
    Set-GradientPanel -Control $header -LeftColor $script:Colors.Blue -RightColor $script:Colors.Purple

    $title = New-Object System.Windows.Forms.Label
    $title.Text = '设置'
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(24, 28)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($title)

    $autoStart = New-Object System.Windows.Forms.CheckBox
    $autoStart.Text = '开机自动启动'
    $autoStart.AutoSize = $true
    $autoStart.Location = New-Object System.Drawing.Point(28, 78)
    $autoStart.BackColor = $script:Colors.Surface
    $autoStart.ForeColor = $script:Colors.Text
    $autoStart.Checked = Test-AutoStartEnabled
    $dialog.Controls.Add($autoStart)

    $autoHint = New-Object System.Windows.Forms.Label
    $autoHint.Text = '使用当前用户的启动项，不需要管理员权限。'
    $autoHint.AutoSize = $true
    $autoHint.Location = New-Object System.Drawing.Point(48, 104)
    $autoHint.ForeColor = $script:Colors.Muted
    $autoHint.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $dialog.Controls.Add($autoHint)

    $themeLabel = New-Object System.Windows.Forms.Label
    $themeLabel.Text = '界面模式'
    $themeLabel.AutoSize = $true
    $themeLabel.Location = New-Object System.Drawing.Point(28, 142)
    $themeLabel.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($themeLabel)

    $themeBox = New-Object System.Windows.Forms.ComboBox
    $themeBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $themeBox.Location = New-Object System.Drawing.Point(110, 138)
    $themeBox.Size = New-Object System.Drawing.Size(160, 30)
    [void]$themeBox.Items.Add('浅色模式')
    [void]$themeBox.Items.Add('深色模式')
    [void]$themeBox.Items.Add('库洛米主题')
    [void]$themeBox.Items.Add('皮卡丘主题')
    [void]$themeBox.Items.Add('猪猪侠主题')
    $themeBox.SelectedIndex = Get-ThemeIndex -Value $script:Config.Preferences.Theme
    $dialog.Controls.Add($themeBox)

    $themePreview = New-Object System.Windows.Forms.PictureBox
    $themePreview.Location = New-Object System.Drawing.Point(310, 124)
    $themePreview.Size = New-Object System.Drawing.Size(54, 54)
    $themePreview.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $themePreview.BackColor = Get-ThemeImageBackColor -Theme $script:Config.Preferences.Theme
    $themePreview.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $dialog.Controls.Add($themePreview)

    $updateThemePreview = {
        $previewTheme = Get-ThemeFromIndex -Index $themeBox.SelectedIndex
        $image = Get-ThemeImage -Theme $previewTheme -Kind 'badge'
        if ($null -eq $image) {
            $themePreview.Image = $null
            $themePreview.Visible = $false
            return
        }

        $themePreview.Image = $image
        $themePreview.BackColor = Get-ThemeImageBackColor -Theme $previewTheme
        $themePreview.Visible = $true
    }
    & $updateThemePreview
    $themeBox.Add_SelectedIndexChanged({
        & $updateThemePreview
    })

    $soundEnabled = New-Object System.Windows.Forms.CheckBox
    $soundEnabled.Text = '弹窗播放声音'
    $soundEnabled.AutoSize = $true
    $soundEnabled.Location = New-Object System.Drawing.Point(28, 180)
    $soundEnabled.BackColor = $script:Colors.Surface
    $soundEnabled.ForeColor = $script:Colors.Text
    $soundEnabled.Checked = [bool]$script:Config.Preferences.SoundEnabled
    $dialog.Controls.Add($soundEnabled)

    $strongPopup = New-Object System.Windows.Forms.CheckBox
    $strongPopup.Text = '饭点强提醒'
    $strongPopup.AutoSize = $true
    $strongPopup.Location = New-Object System.Drawing.Point(164, 180)
    $strongPopup.BackColor = $script:Colors.Surface
    $strongPopup.ForeColor = $script:Colors.Text
    $strongPopup.Checked = [bool]$script:Config.Preferences.StrongPopup
    $dialog.Controls.Add($strongPopup)

    $focusSettings = Get-FocusDoNotDisturb
    $focusDelayMinutes = Get-FocusMaxDelayMinutes
    $dialog.Tag = [pscustomobject]@{
        FocusDelayMinutes = $focusDelayMinutes
    }
    $focusDnd = New-Object System.Windows.Forms.CheckBox
    $focusDnd.Text = '专注勿扰'
    $focusDnd.AutoSize = $true
    $focusDnd.Location = New-Object System.Drawing.Point(300, 180)
    $focusDnd.BackColor = $script:Colors.Surface
    $focusDnd.ForeColor = $script:Colors.Text
    $focusDnd.Checked = [bool]$focusSettings.Enabled
    $dialog.Controls.Add($focusDnd)

    $focusHint = New-Object System.Windows.Forms.Label
    $focusHint.AutoSize = $false
    $focusHint.Text = ('开启后：键鼠静止 60 秒再弹，最多延迟 {0} 分钟。' -f $focusDelayMinutes)
    $focusHint.Location = New-Object System.Drawing.Point(48, 206)
    $focusHint.Size = New-Object System.Drawing.Size(400, 22)
    $focusHint.ForeColor = $script:Colors.Muted
    $focusHint.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $dialog.Controls.Add($focusHint)

    $focusDnd.Add_CheckedChanged({
        param($sender, $e)
        if (-not $sender.Checked) {
            $focusHint.Text = '专注勿扰已关闭。'
            return
        }

        $selectedDelay = Show-FocusDoNotDisturbDialog -OwnerForm $sender.FindForm()
        if ($null -eq $selectedDelay) {
            $sender.Checked = $false
            return
        }

        $sender.FindForm().Tag.FocusDelayMinutes = [int]$selectedDelay
        $focusHint.Text = ('开启后：键鼠静止 60 秒再弹，最多延迟 {0} 分钟。' -f [int]$selectedDelay)
    })

    $dailyTitle = New-Object System.Windows.Forms.Label
    $dailyTitle.Text = '每日提醒'
    $dailyTitle.AutoSize = $true
    $dailyTitle.Location = New-Object System.Drawing.Point(28, 244)
    $dailyTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $dailyTitle.ForeColor = $script:Colors.Text
    $dialog.Controls.Add($dailyTitle)

    $dailyHint = New-Object System.Windows.Forms.Label
    $dailyHint.Text = '取消勾选可单独屏蔽对应提醒。'
    $dailyHint.AutoSize = $true
    $dailyHint.Location = New-Object System.Drawing.Point(112, 246)
    $dailyHint.ForeColor = $script:Colors.Muted
    $dailyHint.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $dialog.Controls.Add($dailyHint)

    $dailyControls = @{}
    $addDailyRow = {
        param(
            [string]$Name,
            [int]$Top,
            [int]$DefaultHour,
            [int]$DefaultMinute
        )

        $item = $script:Config.DailyReminders.$Name
        $timeParts = Get-DailyReminderTimeParts -TimeText $item.Time -DefaultHour $DefaultHour -DefaultMinute $DefaultMinute

        $enabledBox = New-Object System.Windows.Forms.CheckBox
        $enabledBox.Text = (Get-DailyReminderLabel -Name $Name)
        $enabledBox.AutoSize = $false
        $enabledBox.Size = New-Object System.Drawing.Size(96, 28)
        $enabledBox.Location = New-Object System.Drawing.Point(28, $Top)
        $enabledBox.BackColor = $script:Colors.Surface
        $enabledBox.ForeColor = $script:Colors.Text
        $enabledBox.Checked = [bool]$item.Enabled
        $dialog.Controls.Add($enabledBox)

        $hourBox = New-Object System.Windows.Forms.NumericUpDown
        $hourBox.Location = New-Object System.Drawing.Point(136, $Top)
        $hourBox.Size = New-Object System.Drawing.Size(78, 30)
        $hourBox.Minimum = 0
        $hourBox.Maximum = 23
        $hourBox.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
        $hourBox.Value = $timeParts.Hour
        $dialog.Controls.Add($hourBox)

        $colon = New-Object System.Windows.Forms.Label
        $colon.Text = ':'
        $colon.AutoSize = $false
        $colon.Size = New-Object System.Drawing.Size(18, 28)
        $colon.Location = New-Object System.Drawing.Point(218, ($Top + 2))
        $colon.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
        $colon.ForeColor = $script:Colors.Text
        $dialog.Controls.Add($colon)

        $minuteBox = New-Object System.Windows.Forms.NumericUpDown
        $minuteBox.Location = New-Object System.Drawing.Point(240, $Top)
        $minuteBox.Size = New-Object System.Drawing.Size(78, 30)
        $minuteBox.Minimum = 0
        $minuteBox.Maximum = 59
        $minuteBox.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Center
        $minuteBox.Value = $timeParts.Minute
        $dialog.Controls.Add($minuteBox)

        $unitLabel = New-Object System.Windows.Forms.Label
        $unitLabel.Text = '时 : 分'
        $unitLabel.AutoSize = $true
        $unitLabel.Location = New-Object System.Drawing.Point(332, ($Top + 5))
        $unitLabel.ForeColor = $script:Colors.Muted
        $unitLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
        $dialog.Controls.Add($unitLabel)

        $dailyControls[$Name] = [pscustomobject]@{
            Enabled = $enabledBox
            Hour = $hourBox
            Minute = $minuteBox
        }
    }

    & $addDailyRow -Name 'Lunch' -Top 280 -DefaultHour 11 -DefaultMinute 27
    & $addDailyRow -Name 'Dinner' -Top 318 -DefaultHour 17 -DefaultMinute 37
    & $addDailyRow -Name 'Overtime' -Top 356 -DefaultHour 20 -DefaultMinute 58

    $error = New-Object System.Windows.Forms.Label
    $error.AutoSize = $false
    $error.Text = ''
    $error.Location = New-Object System.Drawing.Point(28, 398)
    $error.Size = New-Object System.Drawing.Size(440, 22)
    $error.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
    $dialog.Controls.Add($error)

    $saveBtn = New-Object System.Windows.Forms.Button
    $saveBtn.Text = '保存'
    $saveBtn.Size = New-Object System.Drawing.Size(100, 36)
    $saveBtn.Location = New-Object System.Drawing.Point(272, 458)
    $saveBtn.BackColor = $script:Colors.Blue
    $saveBtn.ForeColor = [System.Drawing.Color]::White
    $saveBtn.FlatStyle = 'Flat'
    $saveBtn.FlatAppearance.BorderSize = 0
    $dialog.Controls.Add($saveBtn)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.Size = New-Object System.Drawing.Size(100, 36)
    $cancel.Location = New-Object System.Drawing.Point(380, 458)
    $cancel.BackColor = $script:Colors.Surface
    $cancel.ForeColor = $script:Colors.Text
    $cancel.FlatStyle = 'Flat'
    $cancel.FlatAppearance.BorderColor = $script:Colors.Border
    $cancel.FlatAppearance.BorderSize = 1
    $dialog.Controls.Add($cancel)

    $saveBtn.Add_Click({
        param($sender, $e)

        try {
            Set-AutoStartEnabled -Enabled $autoStart.Checked
        }
        catch {
            $error.Text = $_.Exception.Message
            return
        }

        $themeMode = Get-ThemeFromIndex -Index $themeBox.SelectedIndex
        $script:Config.Preferences.Theme = $themeMode
        $script:Config.Preferences.SoundEnabled = [bool]$soundEnabled.Checked
        $script:Config.Preferences.StrongPopup = [bool]$strongPopup.Checked
        $script:Config.Preferences.FocusDoNotDisturb.Enabled = [bool]$focusDnd.Checked
        $script:Config.Preferences.FocusDoNotDisturb.IdleSeconds = 60
        $script:Config.Preferences.FocusDoNotDisturb.MaxDelayMinutes = [int]$dialog.Tag.FocusDelayMinutes
        foreach ($name in 'Lunch', 'Dinner', 'Overtime') {
            $row = $dailyControls[$name]
            $timeText = Format-ReminderTime -Hour ([int]$row.Hour.Value) -Minute ([int]$row.Minute.Value)
            Set-DailyReminderSettings -Name $name -Enabled ([bool]$row.Enabled.Checked) -TimeText $timeText
        }
        Save-Config
        Set-ThemeColors -Theme $themeMode
        Apply-MainTheme
        Update-MainStatus
        Update-ClockDisplay
        Write-AppLog -Event 'SettingsSaved' -Message ('主题={0}，每日提醒={1}，{2}' -f (Get-ThemeDisplayName -Value $themeMode), (Get-NextDailyText), (Get-FocusDoNotDisturbText))

        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $cancel.Add_Click({
        param($sender, $e)
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dialog.Close()
    })

    $dialog.Add_Shown({
        param($sender, $e)
        Enable-WindowGlass -Form $sender
        Start-FormFadeIn -Form $sender -TargetOpacity 0.98
    })

    $result = $dialog.ShowDialog($OwnerForm)
    if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
        Show-Toast -Message '设置已保存' -Accent $script:Colors.Green
    }
}

function Show-ReminderPopup {
    param(
        [string]$TitleText,
        [string]$MessageText,
        [string]$KeyName,
        [bool]$Strong = $false,
        [bool]$Sound = $true
    )

    if ($script:ActivePopupForm -and -not $script:ActivePopupForm.IsDisposed -and $script:ActivePopupForm.Visible) {
        return $false
    }

    $script:ActivePopup = $null
    $script:ActivePopupForm = $null

    $popup = New-Object System.Windows.Forms.Form
    $popup.Text = $TitleText
    Set-FormThemeIdentity -Form $popup -Suffix $TitleText
    $popup.Tag = [pscustomobject]@{
        TitleText = $TitleText
        MessageText = $MessageText
        KeyName = $KeyName
        Strong = $Strong
        Sound = $Sound
    }
    $popup.StartPosition = 'CenterScreen'
    $popup.FormBorderStyle = 'FixedDialog'
    $popup.MaximizeBox = $false
    $popup.MinimizeBox = $false
    $popup.ShowInTaskbar = $true
    $popup.TopMost = $true
    $popup.BackColor = $script:Colors.Surface
    $popup.ClientSize = New-Object System.Drawing.Size(560, 300)
    $popup.Font = New-Object System.Drawing.Font('Segoe UI', 10)

    $popup.Add_FormClosed({
        $script:ActivePopup = $null
        $script:ActivePopupForm = $null
        Update-MainStatus
    })

    $left = New-Object System.Windows.Forms.Panel
    $left.Location = New-Object System.Drawing.Point(0, 0)
    $left.Size = New-Object System.Drawing.Size(0, 300)
    $left.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left
    $popup.Controls.Add($left)

    $headline = if ($Strong) {
        [System.Drawing.Color]::FromArgb(220, 38, 38)
    }
    elseif ($KeyName -eq 'Lunch') {
        $script:Colors.Blue
    }
    elseif ($KeyName -eq 'Dinner') {
        $script:Colors.Orange
    }
    elseif ($KeyName -eq 'Overtime') {
        $script:Colors.Purple
    }
    else {
        $script:Colors.Green
    }
    Set-GradientPanel -Control $left -LeftColor $headline -RightColor $script:Colors.Green

    $body = New-Object System.Windows.Forms.Panel
    $body.Location = New-Object System.Drawing.Point(0, 0)
    $body.Size = New-Object System.Drawing.Size(560, 300)
    $body.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $body.BackColor = $script:Colors.Surface
    $popup.Controls.Add($body)

    $title = New-Object System.Windows.Forms.Label
    $title.AutoSize = $false
    $title.Text = $TitleText
    $title.Location = New-Object System.Drawing.Point(24, 24)
    $title.Size = New-Object System.Drawing.Size(376, 42)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $script:Colors.Text
    $body.Controls.Add($title)

    $popupArt = New-Object System.Windows.Forms.PictureBox
    $popupArt.Location = New-Object System.Drawing.Point(420, 20)
    $popupArt.Size = New-Object System.Drawing.Size(104, 104)
    $popupArt.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $popupArt.BackColor = Get-ThemeImageBackColor -Theme $script:Config.Preferences.Theme
    $popupArt.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $popupArt.Visible = $false
    Set-ThemedPicture -PictureBox $popupArt -Kind 'popup'
    $body.Controls.Add($popupArt)

    $message = New-Object System.Windows.Forms.Label
    $message.AutoSize = $false
    $message.Text = $MessageText
    $message.Location = New-Object System.Drawing.Point(24, 80)
    $message.Size = New-Object System.Drawing.Size(370, 62)
    $message.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular)
    $message.ForeColor = $script:Colors.Muted
    $body.Controls.Add($message)

    $themeRibbon = New-Object System.Windows.Forms.Label
    $themeRibbon.AutoSize = $false
    $themeRibbon.Text = Get-ThemeElementText -Value $script:Config.Preferences.Theme
    $themeRibbon.Location = New-Object System.Drawing.Point(300, 154)
    $themeRibbon.Size = New-Object System.Drawing.Size(212, 36)
    $themeRibbon.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $themeRibbon.BackColor = $script:Colors.PurpleSoft
    $themeRibbon.ForeColor = $script:Colors.Purple
    $themeRibbon.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $body.Controls.Add($themeRibbon)

    $snooze5 = New-Object System.Windows.Forms.Button
    $snooze5.Text = '5分钟后'
    $snooze5.Size = New-Object System.Drawing.Size(82, 36)
    $snooze5.Location = New-Object System.Drawing.Point(24, 154)
    $snooze5.BackColor = $script:Colors.OrangeSoft
    $snooze5.ForeColor = $script:Colors.Orange
    $snooze5.FlatStyle = 'Flat'
    $snooze5.FlatAppearance.BorderColor = $script:Colors.Border
    $snooze5.FlatAppearance.BorderSize = 1
    $body.Controls.Add($snooze5)

    $snooze10 = New-Object System.Windows.Forms.Button
    $snooze10.Text = '10分钟后'
    $snooze10.Size = New-Object System.Drawing.Size(82, 36)
    $snooze10.Location = New-Object System.Drawing.Point(114, 154)
    $snooze10.BackColor = $script:Colors.OrangeSoft
    $snooze10.ForeColor = $script:Colors.Orange
    $snooze10.FlatStyle = 'Flat'
    $snooze10.FlatAppearance.BorderColor = $script:Colors.Border
    $snooze10.FlatAppearance.BorderSize = 1
    $body.Controls.Add($snooze10)

    $snooze30 = New-Object System.Windows.Forms.Button
    $snooze30.Text = '30分钟后'
    $snooze30.Size = New-Object System.Drawing.Size(82, 36)
    $snooze30.Location = New-Object System.Drawing.Point(204, 154)
    $snooze30.BackColor = $script:Colors.OrangeSoft
    $snooze30.ForeColor = $script:Colors.Orange
    $snooze30.FlatStyle = 'Flat'
    $snooze30.FlatAppearance.BorderColor = $script:Colors.Border
    $snooze30.FlatAppearance.BorderSize = 1
    $body.Controls.Add($snooze30)

    $settings = New-Object System.Windows.Forms.Button
    $settings.Text = '设置下次单次提醒时间'
    $settings.Size = New-Object System.Drawing.Size(210, 42)
    $settings.Location = New-Object System.Drawing.Point(24, 204)
    $settings.BackColor = $script:Colors.Blue
    $settings.ForeColor = [System.Drawing.Color]::White
    $settings.FlatStyle = 'Flat'
    $settings.FlatAppearance.BorderSize = 0
    $body.Controls.Add($settings)

    $know = New-Object System.Windows.Forms.Button
    $know.Text = '朕知道了'
    $know.Size = New-Object System.Drawing.Size(120, 42)
    $know.Location = New-Object System.Drawing.Point(246, 204)
    $know.BackColor = $script:Colors.Surface
    $know.ForeColor = $script:Colors.Text
    $know.FlatStyle = 'Flat'
    $know.FlatAppearance.BorderColor = $script:Colors.Border
    $know.FlatAppearance.BorderSize = 1
    $body.Controls.Add($know)

    $footer = New-Object System.Windows.Forms.Label
    $footer.AutoSize = $false
    $footer.Text = if ($Strong) {
        '强提醒已开启：忙完再看可点贪睡，点击“朕知道了”即可关闭。'
    }
    else {
        '提示：忙完再看可点贪睡，点击“朕知道了”即可关闭。'
    }
    $footer.Location = New-Object System.Drawing.Point(24, 258)
    $footer.Size = New-Object System.Drawing.Size(488, 22)
    $footer.ForeColor = $script:Colors.Muted
    $body.Controls.Add($footer)

    $snoozeHandler = {
        param($sender, $e)
        $state = $sender.Tag
        Set-SnoozeReminder -TitleText $state.TitleText -MessageText $state.MessageText -KeyName $state.KeyName -Minutes ([int]$state.Minutes)
        $sender.FindForm().Close()
    }

    $snooze5.Tag = [pscustomobject]@{
        Minutes = 5
        TitleText = $TitleText
        MessageText = $MessageText
        KeyName = $KeyName
    }
    $snooze10.Tag = [pscustomobject]@{
        Minutes = 10
        TitleText = $TitleText
        MessageText = $MessageText
        KeyName = $KeyName
    }
    $snooze30.Tag = [pscustomobject]@{
        Minutes = 30
        TitleText = $TitleText
        MessageText = $MessageText
        KeyName = $KeyName
    }
    $snooze5.Add_Click($snoozeHandler)
    $snooze10.Add_Click($snoozeHandler)
    $snooze30.Add_Click($snoozeHandler)

    $settings.Add_Click({
        param($sender, $e)
        Show-SingleReminderDialog -OwnerForm $sender.FindForm()
    })

    $know.Add_Click({
        param($sender, $e)
        $state = $sender.FindForm().Tag
        Write-AppLog -Event 'PopupAcknowledged' -Message ('{0} | Key={1}' -f $state.TitleText, $state.KeyName)
        $sender.FindForm().Close()
    })

    $popup.Add_Shown({
        param($sender, $e)
        try {
            $state = $sender.Tag
            Enable-WindowGlass -Form $sender
            Start-FormFadeIn -Form $sender -TargetOpacity 0.98
            if ([bool]$state.Sound) {
                Play-ReminderSound -Strong ([bool]$state.Strong)
            }
            $sender.Activate()
        }
        catch {
            Write-AppLog -Event 'PopupShownFailed' -Message $_.Exception.Message -Level 'ERROR'
        }
    })

    $script:ActivePopup = $KeyName
    $script:ActivePopupForm = $popup
    Write-AppLog -Event 'PopupShown' -Message ('{0} | {1} | Key={2}' -f $TitleText, $MessageText, $KeyName)

    try {
        [void]$popup.Show()
        return $true
    }
    catch {
        $script:ActivePopup = $null
        $script:ActivePopupForm = $null
        return $false
    }
}

function Test-ReminderDue {
    param(
        [datetime]$Now,
        [string]$ReminderTime,
        [string]$LastFiredDate
    )

    try {
        $target = Get-ScheduledDateTime -TimeText $ReminderTime
    }
    catch {
        return $false
    }

    return (Test-ReminderReady -Now $Now -DueAt $target -LastFiredDate $LastFiredDate)
}

function Check-Reminders {
    $now = [datetime]::Now
    if ($script:Config.Mode -eq 'Trip') {
        Update-MainStatus
        return
    }

    if (Test-TodayPauseActive) {
        Update-MainStatus
        return
    }

    if ($script:Config.SnoozeReminder -and [bool]$script:Config.SnoozeReminder.Enabled) {
        $snoozeUntil = Get-SnoozeUntil
        if ($null -ne $snoozeUntil -and $now -ge $snoozeUntil) {
            if (Test-FocusShouldDelay -Now $now -DueAt $snoozeUntil) {
                Update-MainStatus
                return
            }

            if (Show-ReminderPopup -TitleText $script:Config.SnoozeReminder.Title -MessageText $script:Config.SnoozeReminder.Message -KeyName $script:Config.SnoozeReminder.KeyName -Strong ([bool]$script:Config.Preferences.StrongPopup) -Sound ([bool]$script:Config.Preferences.SoundEnabled)) {
                Write-AppLog -Event 'SnoozeFired' -Message ('贪睡提醒触发：{0}' -f $script:Config.SnoozeReminder.Title)
                $script:Config.SnoozeReminder.Enabled = $false
                $script:Config.SnoozeReminder.Until = $null
                Save-Config
                Update-MainStatus
                return
            }
        }
    }

    foreach ($name in 'Lunch', 'Dinner', 'Overtime') {
        $item = $script:Config.DailyReminders.$name
        if (-not $item.Enabled) {
            continue
        }

        try {
            $dueAt = Get-ScheduledDateTime -TimeText $item.Time
        }
        catch {
            continue
        }

        if (Test-ReminderReady -Now $now -DueAt $dueAt -LastFiredDate $item.LastFiredDate) {
            if (Show-ReminderPopup -TitleText $item.Title -MessageText $item.Message -KeyName $name -Strong ([bool]$script:Config.Preferences.StrongPopup) -Sound ([bool]$script:Config.Preferences.SoundEnabled)) {
                Write-AppLog -Event 'DailyFired' -Message ('{0} 提醒触发，计划时间 {1}' -f (Get-DailyReminderLabel -Name $name), $item.Time)
                $item.LastFiredDate = $now.ToString('yyyy-MM-dd')
                Save-Config
                Update-MainStatus
                return
            }
        }
    }

    foreach ($item in (Get-CustomReminderList)) {
        if (-not [bool]$item.Enabled) {
            continue
        }

        try {
            $dueAt = Get-ScheduledDateTime -TimeText $item.Time
        }
        catch {
            continue
        }

        if (Test-ReminderReady -Now $now -DueAt $dueAt -LastFiredDate $item.LastFiredDate) {
            if (Show-ReminderPopup -TitleText $item.Title -MessageText $item.Message -KeyName ('Custom:{0}' -f $item.Id) -Strong ([bool]$item.Strong) -Sound ([bool]$item.Sound)) {
                Write-AppLog -Event 'CustomFired' -Message ('{0} 提醒触发，计划时间 {1}' -f $item.Title, $item.Time)
                $item.LastFiredDate = $now.ToString('yyyy-MM-dd')
                Save-Config
                Update-MainStatus
                return
            }
        }
    }

    $single = $script:Config.SingleReminder
    if ($single.Enabled -and -not $single.Triggered -and -not [string]::IsNullOrWhiteSpace($single.At)) {
        $when = ConvertTo-SingleReminderDateTime -At $single.At -BaseNow $now
        if ($null -ne $when -and (Test-ReminderReady -Now $now -DueAt $when -LastFiredDate $null)) {
            if (Show-ReminderPopup -TitleText $single.Label -MessageText $single.Message -KeyName 'Single' -Strong ([bool]$script:Config.Preferences.StrongPopup) -Sound ([bool]$script:Config.Preferences.SoundEnabled)) {
                Write-AppLog -Event 'SingleFired' -Message ('单次提醒触发：{0}' -f (Format-SingleReminderDisplay -At $when))
                $script:Config.SingleReminder.Triggered = $true
                Save-Config
                Update-MainStatus
            }
        }
    }
}

function Build-MainForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $script:AppName
    Set-FormThemeIdentity -Form $form
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $script:Colors.Background
    $form.ClientSize = New-Object System.Drawing.Size(720, 500)
    $form.MinimumSize = New-Object System.Drawing.Size(680, 460)
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    Set-FormBackdrop -Form $form

    $form.Add_FormClosing({
        if (-not $script:ShouldExit) {
            $_.Cancel = $true
            $script:MainForm.Hide()
        }
    })

    $top = New-Object System.Windows.Forms.Panel
    $top.Dock = 'Top'
    $top.Height = 10
    $form.Controls.Add($top)
    Set-GradientPanel -Control $top -LeftColor $script:Colors.Blue -RightColor $script:Colors.Purple

    $themeBanner = New-Object System.Windows.Forms.PictureBox
    $themeBanner.Location = New-Object System.Drawing.Point(378, 86)
    $themeBanner.Size = New-Object System.Drawing.Size(310, 22)
    $themeBanner.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $themeBanner.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $themeBanner.BackColor = $script:Colors.Background
    $themeBanner.Visible = $false
    $form.Controls.Add($themeBanner)

    $title = New-Object System.Windows.Forms.Label
    $title.Text = ''
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(28, 30)
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 22, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $script:Colors.Text
    $form.Controls.Add($title)

    $themeIcon = New-Object System.Windows.Forms.PictureBox
    $themeIcon.Location = New-Object System.Drawing.Point(28, 26)
    $themeIcon.Size = New-Object System.Drawing.Size(64, 64)
    $themeIcon.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $themeIcon.BackColor = $script:Colors.Background
    $themeIcon.Visible = $false
    $form.Controls.Add($themeIcon)

    $clockPanel = New-Object System.Windows.Forms.Panel
    $clockPanel.Size = New-Object System.Drawing.Size(210, 58)
    $clockPanel.Location = New-Object System.Drawing.Point(478, 28)
    $clockPanel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $clockPanel.BackColor = $script:Colors.Surface
    $clockPanel.BorderStyle = 'None'
    Set-GlassPanel -Control $clockPanel -Radius 18
    $form.Controls.Add($clockPanel)

    $clockCaption = New-Object System.Windows.Forms.Label
    $clockCaption.Text = '当前时间'
    $clockCaption.AutoSize = $true
    $clockCaption.Location = New-Object System.Drawing.Point(14, 9)
    $clockCaption.ForeColor = $script:Colors.Muted
    $clockCaption.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Regular)
    $clockPanel.Controls.Add($clockCaption)

    $script:ClockLabel = New-Object System.Windows.Forms.Label
    $script:ClockLabel.Text = '--:--:--'
    $script:ClockLabel.AutoSize = $false
    $script:ClockLabel.Location = New-Object System.Drawing.Point(88, 6)
    $script:ClockLabel.Size = New-Object System.Drawing.Size(108, 26)
    $script:ClockLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $script:ClockLabel.ForeColor = $script:Colors.Blue
    $script:ClockLabel.Font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold)
    $clockPanel.Controls.Add($script:ClockLabel)

    $script:ClockDateLabel = New-Object System.Windows.Forms.Label
    $script:ClockDateLabel.Text = ''
    $script:ClockDateLabel.AutoSize = $false
    $script:ClockDateLabel.Location = New-Object System.Drawing.Point(14, 34)
    $script:ClockDateLabel.Size = New-Object System.Drawing.Size(182, 18)
    $script:ClockDateLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    $script:ClockDateLabel.ForeColor = $script:Colors.Muted
    $script:ClockDateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Regular)
    $clockPanel.Controls.Add($script:ClockDateLabel)

    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = '低占用常驻监测，单次提醒支持顺延或固定时刻。'
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(108, 38)
    $subtitle.ForeColor = $script:Colors.Muted
    $form.Controls.Add($subtitle)

    $themeBadge = New-Object System.Windows.Forms.Label
    $themeBadge.Text = Get-ThemeElementText -Value $script:Config.Preferences.Theme
    $themeBadge.AutoSize = $true
    $themeBadge.Location = New-Object System.Drawing.Point(108, 66)
    $themeBadge.ForeColor = $script:Colors.Purple
    $themeBadge.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($themeBadge)

    $card = New-Object System.Windows.Forms.Panel
    $card.Location = New-Object System.Drawing.Point(28, 112)
    $card.Size = New-Object System.Drawing.Size(660, 220)
    $card.BackColor = $script:Colors.Surface
    $card.BorderStyle = 'None'
    Set-GlassPanel -Control $card -Radius 22
    $form.Controls.Add($card)

    $statusTitle = New-Object System.Windows.Forms.Label
    $statusTitle.Text = '当前状态'
    $statusTitle.AutoSize = $true
    $statusTitle.Location = New-Object System.Drawing.Point(20, 18)
    $statusTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $statusTitle.ForeColor = $script:Colors.Text
    $card.Controls.Add($statusTitle)

    $script:StatusLabel = New-Object System.Windows.Forms.Label
    $script:StatusLabel.Text = '当前模式：公司上班'
    $script:StatusLabel.AutoSize = $true
    $script:StatusLabel.Location = New-Object System.Drawing.Point(20, 48)
    $script:StatusLabel.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Regular)
    $script:StatusLabel.ForeColor = $script:Colors.Blue
    $card.Controls.Add($script:StatusLabel)

    $script:DetailLabel = New-Object System.Windows.Forms.Label
    $script:DetailLabel.AutoSize = $false
    $script:DetailLabel.Text = ''
    $script:DetailLabel.Location = New-Object System.Drawing.Point(20, 178)
    $script:DetailLabel.Size = New-Object System.Drawing.Size(620, 24)
    $script:DetailLabel.ForeColor = $script:Colors.Muted
    $script:DetailLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Regular)
    $card.Controls.Add($script:DetailLabel)

    $dailyRows = @{}
    $addMainDailyRow = {
        param(
            [string]$Name,
            [int]$Top
        )

        $timeLabel = New-Object System.Windows.Forms.Label
        $timeLabel.AutoSize = $false
        $timeLabel.Text = ''
        $timeLabel.Location = New-Object System.Drawing.Point(20, $Top)
        $timeLabel.Size = New-Object System.Drawing.Size(190, 26)
        $timeLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $timeLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Regular)
        $timeLabel.ForeColor = $script:Colors.Text
        $card.Controls.Add($timeLabel)

        $stateLabel = New-Object System.Windows.Forms.Label
        $stateLabel.AutoSize = $false
        $stateLabel.Text = ''
        $stateLabel.Location = New-Object System.Drawing.Point(226, $Top)
        $stateLabel.Size = New-Object System.Drawing.Size(250, 26)
        $stateLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $stateLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
        $stateLabel.ForeColor = $script:Colors.Muted
        $card.Controls.Add($stateLabel)

        $toggleButton = New-Object System.Windows.Forms.Button
        $toggleButton.Name = $Name
        $toggleButton.Text = '屏蔽'
        $toggleButton.Size = New-Object System.Drawing.Size(92, 28)
        $toggleButton.Location = New-Object System.Drawing.Point(548, ($Top - 1))
        $toggleButton.FlatStyle = 'Flat'
        $toggleButton.FlatAppearance.BorderSize = 1
        $card.Controls.Add($toggleButton)
        $toggleButton.Add_Click({
            param($sender, $e)
            Toggle-DailyReminderBlock -Name $sender.Name
        })

        $dailyRows[$Name] = [pscustomobject]@{
            TimeLabel = $timeLabel
            StateLabel = $stateLabel
            ToggleButton = $toggleButton
        }
    }

    & $addMainDailyRow -Name 'Lunch' -Top 82
    & $addMainDailyRow -Name 'Dinner' -Top 112
    & $addMainDailyRow -Name 'Overtime' -Top 142
    $script:DailyReminderRows = $dailyRows

    $btnCompany = New-Object System.Windows.Forms.Button
    $btnCompany.Text = '公司上班'
    $btnCompany.Size = New-Object System.Drawing.Size(102, 44)
    $btnCompany.Location = New-Object System.Drawing.Point(28, 356)
    $btnCompany.BackColor = $script:Colors.Blue
    $btnCompany.ForeColor = [System.Drawing.Color]::White
    $btnCompany.FlatStyle = 'Flat'
    $btnCompany.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnCompany)

    $btnTrip = New-Object System.Windows.Forms.Button
    $btnTrip.Text = '出差中'
    $btnTrip.Size = New-Object System.Drawing.Size(102, 44)
    $btnTrip.Location = New-Object System.Drawing.Point(138, 356)
    $btnTrip.BackColor = $script:Colors.Orange
    $btnTrip.ForeColor = [System.Drawing.Color]::White
    $btnTrip.FlatStyle = 'Flat'
    $btnTrip.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnTrip)

    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text = '测试弹窗'
    $btnTest.Size = New-Object System.Drawing.Size(102, 44)
    $btnTest.Location = New-Object System.Drawing.Point(248, 356)
    $btnTest.BackColor = $script:Colors.Green
    $btnTest.ForeColor = [System.Drawing.Color]::White
    $btnTest.FlatStyle = 'Flat'
    $btnTest.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnTest)

    $btnCustom = New-Object System.Windows.Forms.Button
    $btnCustom.Text = '更多'
    $btnCustom.Size = New-Object System.Drawing.Size(102, 44)
    $btnCustom.Location = New-Object System.Drawing.Point(358, 356)
    $btnCustom.BackColor = $script:Colors.BlueSoft
    $btnCustom.ForeColor = $script:Colors.Blue
    $btnCustom.FlatStyle = 'Flat'
    $btnCustom.FlatAppearance.BorderColor = $script:Colors.Border
    $btnCustom.FlatAppearance.BorderSize = 1
    $form.Controls.Add($btnCustom)

    $btnSettings = New-Object System.Windows.Forms.Button
    $btnSettings.Text = '设置'
    $btnSettings.Size = New-Object System.Drawing.Size(102, 44)
    $btnSettings.Location = New-Object System.Drawing.Point(468, 356)
    $btnSettings.BackColor = $script:Colors.Purple
    $btnSettings.ForeColor = [System.Drawing.Color]::White
    $btnSettings.FlatStyle = 'Flat'
    $btnSettings.FlatAppearance.BorderSize = 0
    $btnSettings.Visible = $false
    $form.Controls.Add($btnSettings)

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = '退出'
    $btnExit.Size = New-Object System.Drawing.Size(80, 44)
    $btnExit.Location = New-Object System.Drawing.Point(608, 356)
    $btnExit.BackColor = $script:Colors.Surface
    $btnExit.ForeColor = $script:Colors.Text
    $btnExit.FlatStyle = 'Flat'
    $btnExit.FlatAppearance.BorderColor = $script:Colors.Border
    $btnExit.FlatAppearance.BorderSize = 1
    $btnExit.Visible = $false
    $form.Controls.Add($btnExit)

    $btnPauseToday = New-Object System.Windows.Forms.Button
    $btnPauseToday.Text = '今日暂停'
    $btnPauseToday.Size = New-Object System.Drawing.Size(102, 34)
    $btnPauseToday.Location = New-Object System.Drawing.Point(468, 414)
    $btnPauseToday.BackColor = $script:Colors.OrangeSoft
    $btnPauseToday.ForeColor = $script:Colors.Orange
    $btnPauseToday.FlatStyle = 'Flat'
    $btnPauseToday.FlatAppearance.BorderColor = $script:Colors.Border
    $btnPauseToday.FlatAppearance.BorderSize = 1
    $btnPauseToday.Visible = $false
    $form.Controls.Add($btnPauseToday)

    $tip = New-Object System.Windows.Forms.Label
    $tip.Text = '关闭窗口会缩到系统托盘。'
    $tip.AutoSize = $true
    $tip.Location = New-Object System.Drawing.Point(28, 422)
    $tip.ForeColor = $script:Colors.Muted
    $form.Controls.Add($tip)

    $script:MainThemeControls = [pscustomobject]@{
        Form = $form
        Top = $top
        ThemeBanner = $themeBanner
        ThemeIcon = $themeIcon
        Title = $title
        Subtitle = $subtitle
        ThemeBadge = $themeBadge
        ClockPanel = $clockPanel
        ClockCaption = $clockCaption
        Card = $card
        StatusTitle = $statusTitle
        BtnCompany = $btnCompany
        BtnTrip = $btnTrip
        BtnTest = $btnTest
        BtnCustom = $btnCustom
        BtnSettings = $btnSettings
        BtnExit = $btnExit
        BtnPauseToday = $btnPauseToday
        Tip = $tip
    }
    Apply-MainTheme

    $btnCompany.Add_Click({ Set-Mode -Mode 'Company' })
    $btnTrip.Add_Click({ Set-Mode -Mode 'Trip' })
    $btnTest.Add_Click({
        [void](Show-ReminderPopup -TitleText '测试弹窗' -MessageText '这是一个测试弹窗，用来确认界面和按钮效果。' -KeyName 'Test' -Strong ([bool]$script:Config.Preferences.StrongPopup) -Sound ([bool]$script:Config.Preferences.SoundEnabled))
    })

    $moreMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $miMoreCustom = $moreMenu.Items.Add('自定义提醒')
    $miMorePauseToday = $moreMenu.Items.Add('今日暂停提醒')
    $miMoreWorkSchedule = $moreMenu.Items.Add('工作制')
    $miMoreSettings = $moreMenu.Items.Add('设置')
    [void]$moreMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $miMoreExit = $moreMenu.Items.Add('退出')
    $moreMenu.Tag = [pscustomobject]@{
        PauseTodayItem = $miMorePauseToday
    }
    Apply-AppMenuTheme -Menu $moreMenu
    $btnCustom.ContextMenuStrip = $moreMenu
    $moreMenu.Add_Opening({
        param($sender, $e)
        $pauseItem = $sender.Tag.PauseTodayItem
        if ($pauseItem) {
            $pauseItem.Text = if (Test-TodayPauseActive) { '恢复今日提醒' } else { '今日暂停提醒' }
        }
    })

    $btnCustom.Add_Click({
        param($sender, $e)
        $sender.ContextMenuStrip.Show($sender, 0, $sender.Height)
    })
    $miMoreCustom.Add_Click({
        param($sender, $e)
        $ownerForm = if ($sender.Owner -and $sender.Owner.SourceControl) { $sender.Owner.SourceControl.FindForm() } else { $script:MainForm }
        Show-CustomRemindersDialog -OwnerForm $ownerForm
    })
    $miMorePauseToday.Add_Click({
        Toggle-TodayPause
    })
    $miMoreWorkSchedule.Add_Click({
        param($sender, $e)
        $ownerForm = if ($sender.Owner -and $sender.Owner.SourceControl) { $sender.Owner.SourceControl.FindForm() } else { $script:MainForm }
        Show-WorkScheduleDialog -OwnerForm $ownerForm
    })
    $miMoreSettings.Add_Click({
        param($sender, $e)
        $ownerForm = if ($sender.Owner -and $sender.Owner.SourceControl) { $sender.Owner.SourceControl.FindForm() } else { $script:MainForm }
        Show-SettingsDialog -OwnerForm $ownerForm
    })
    $miMoreExit.Add_Click({
        param($sender, $e)
        $ownerForm = if ($sender.Owner -and $sender.Owner.SourceControl) { $sender.Owner.SourceControl.FindForm() } else { $script:MainForm }
        $script:ShouldExit = $true
        $ownerForm.Close()
    })
    $btnSettings.Add_Click({
        param($sender, $e)
        Show-SettingsDialog -OwnerForm $sender.FindForm()
    })
    $btnPauseToday.Add_Click({
        Toggle-TodayPause
    })
    $btnExit.Add_Click({
        param($sender, $e)
        $script:ShouldExit = $true
        $sender.FindForm().Close()
    })

    $form.Add_Shown({
        param($sender, $e)

        if ($script:TrayIcon -eq $null) {
            $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
            $script:TrayIcon.Icon = Get-ThemeIcon -Theme $script:Config.Preferences.Theme
            $script:TrayIcon.Text = Get-ThemeWindowTitle -Theme $script:Config.Preferences.Theme
            $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip

            $miShow = $trayMenu.Items.Add('显示主界面')
            $miCompany = $trayMenu.Items.Add('公司上班')
            $miTrip = $trayMenu.Items.Add('出差中')
            $miPauseToday = $trayMenu.Items.Add('今日暂停提醒')
            $miCustom = $trayMenu.Items.Add('自定义提醒')
            $miWorkSchedule = $trayMenu.Items.Add('工作制')
            $miSettings = $trayMenu.Items.Add('设置')
            [void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
            $miExit = $trayMenu.Items.Add('退出')
            Apply-AppMenuTheme -Menu $trayMenu

            $miShow.Add_Click({
                if ($script:MainForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                    $script:MainForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
                }
                $script:MainForm.Show()
                $script:MainForm.Activate()
            })
            $miCompany.Add_Click({ Set-Mode -Mode 'Company' })
            $miTrip.Add_Click({ Set-Mode -Mode 'Trip' })
            $miPauseToday.Add_Click({ Toggle-TodayPause })
            $miCustom.Add_Click({
                Show-MainWindow
                Show-CustomRemindersDialog -OwnerForm $script:MainForm
            })
            $miWorkSchedule.Add_Click({
                Show-MainWindow
                Show-WorkScheduleDialog -OwnerForm $script:MainForm
            })
            $miSettings.Add_Click({
                Show-MainWindow
                Show-SettingsDialog -OwnerForm $script:MainForm
            })
            $miExit.Add_Click({
                $script:ShouldExit = $true
                $script:TrayIcon.Visible = $false
                $script:TrayIcon.Dispose()
                $script:TrayIcon = $null
                $script:TrayPauseTodayItem = $null
                $script:MainForm.Close()
            })

            $script:TrayIcon.ContextMenuStrip = $trayMenu
            $script:TrayPauseTodayItem = $miPauseToday
            $script:TrayIcon.Visible = $true
            $script:TrayIcon.Add_MouseClick({
                param($sender, $e)
                if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
                    Show-MainWindow
                }
            })
            $script:TrayIcon.Add_DoubleClick({
                Show-MainWindow
            })
        }

        Enable-WindowGlass -Form $sender
        Start-FormFadeIn -Form $sender -TargetOpacity 0.98
        $sender.Show()
        $sender.Activate()
    })

    $reminderTimer = New-Object System.Windows.Forms.Timer
    $reminderTimer.Interval = 15000
    $reminderTimer.Add_Tick({ Check-Reminders })
    $reminderTimer.Add_Tick({ Update-MainStatus })
    $reminderTimer.Add_Tick({ Update-TrayStats })

    $clockTimer = New-Object System.Windows.Forms.Timer
    $clockTimer.Interval = 1000
    $clockTimer.Add_Tick({ Update-ClockDisplay })

    $showRequestTimer = New-Object System.Windows.Forms.Timer
    $showRequestTimer.Interval = 1000
    $showRequestTimer.Add_Tick({ Check-MainWindowShowRequest })

    $form.Tag = [pscustomobject]@{
        ReminderTimer = $reminderTimer
        ClockTimer = $clockTimer
        ShowRequestTimer = $showRequestTimer
    }

    $form.Add_Load({
        param($sender, $e)
        Initialize-ShowRequestState
        Update-MainStatus
        Update-ClockDisplay
        Check-Reminders
        $sender.Tag.ReminderTimer.Start()
        $sender.Tag.ClockTimer.Start()
        $sender.Tag.ShowRequestTimer.Start()
    })

    $form.Add_FormClosed({
        param($sender, $e)
        $sender.Tag.ReminderTimer.Stop()
        $sender.Tag.ClockTimer.Stop()
        $sender.Tag.ShowRequestTimer.Stop()
        if ($script:TrayIcon) {
            $script:TrayIcon.Visible = $false
            $script:TrayIcon.Dispose()
            $script:TrayIcon = $null
            $script:TrayPauseTodayItem = $null
        }
    })

    return $form
}

if (-not (Initialize-SingleInstance)) {
    Request-MainWindowShow
    Write-AppLog -Event 'StartupSkipped' -Message '已有实例运行，已请求显示主界面' -Level 'WARN'
    exit 0
}

$script:Config = Load-Config
Write-AppLog -Event 'Startup' -Message ('程序启动，配置版本={0}，模式={1}，主题={2}' -f $script:Config.Version, $script:Config.Mode, (Get-ThemeDisplayName -Value $script:Config.Preferences.Theme))
Set-ThemeColors -Theme $script:Config.Preferences.Theme
$single = $script:Config.SingleReminder
if ($single.Enabled -and -not $single.Triggered -and -not [string]::IsNullOrWhiteSpace($single.At)) {
    $now = [datetime]::Now
    $when = ConvertTo-SingleReminderDateTime -At $single.At -BaseNow $now
    if ($null -ne $when) {
        if ($single.At -is [string] -and $single.At.Length -eq 5 -and $single.At[2] -eq ':') {
            $script:Config.SingleReminder.At = $when.ToString('o')
        }

        if ($now -ge $when -and $now -le $when.AddMinutes(5)) {
            $script:Config.SingleReminder.Triggered = $true
        }
    }
}
Save-Config

if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    Show-Toast -Message '请使用 STA 模式启动该工具。'
    Release-SingleInstance
    exit 1
}

try {
    $script:MainForm = Build-MainForm
    [System.Windows.Forms.Application]::Run($script:MainForm)
}
finally {
    Write-AppLog -Event 'Exit' -Message '程序退出'
    Release-SingleInstance
}
