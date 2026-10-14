param([hashtable]$Context)
# Set-Item inside a comment is not a command
New-Object System.Text.StringBuilder | Out-Null
Set-Item -Path 'HKCU:\Software\claude-house' -Name Example -Value 1
