#Requires -Version 5.1
<#
  Colors and shared XAML styles.
  Initialize-Theme sets $script:C (color table) and $script:SharedStyles
  (XAML resources inserted into every window's <Window.Resources>).
#>

function Get-ThemeColor {
  @{
    Bg = '#262624'; Bg2 = '#30302E'; Line = '#3D3D3A'; Text = '#F0EEE6'; Text2 = '#C2C0B6'
    Muted = '#8F8D86'; Accent = '#D97757'; Green = '#7FB77E'; Dim = '#55544F'; Ink = '#1F1E1D'
  }
}

function Get-Brush([string]$Hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex) }
function ConvertTo-GridLength([string]$Value) { (New-Object System.Windows.GridLengthConverter).ConvertFromString($Value) }

# Styles: IconBtn (MDL2 glyph buttons), TextBtn, Switch (toggle), Pill (radio).
function Get-SharedStyleXaml($Colors) {
  $C = $Colors
  @"
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Width" Value="26"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Bg2)"/>
                <Setter Property="Foreground" Value="$($C.Text)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TextBtn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="5" Padding="8,4">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Bg2)"/>
                <Setter Property="Foreground" Value="$($C.Text)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="track" Width="36" Height="20" CornerRadius="10" Background="$($C.Line)">
              <Ellipse x:Name="thumb" Width="14" Height="14" Fill="$($C.Text2)" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="$($C.Accent)"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,3,0"/>
                <Setter TargetName="thumb" Property="Fill" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="$($C.Text2)"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="4,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="6" Padding="10,4" Background="$($C.Bg2)" BorderBrush="$($C.Line)" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="$($C.Muted)"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Accent)"/>
                <Setter TargetName="b" Property="BorderBrush" Value="$($C.Accent)"/>
                <Setter Property="Foreground" Value="$($C.Ink)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
"@
}

function Initialize-Theme {
  $script:C = Get-ThemeColor
  $script:SharedStyles = Get-SharedStyleXaml $script:C
}
