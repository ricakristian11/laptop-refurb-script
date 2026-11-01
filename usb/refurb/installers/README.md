Put two installers in this folder:

1. **Dell Command | Update Windows Universal Application** `.exe` from Dell's support site. `audit.ps1` finds any file matching `*Command*Update*.exe` and installs it silently with `/s`.
2. The **.NET Desktop Runtime** x64 installer (`windowsdesktop-runtime-...-win-x64.exe`) from Microsoft, in the version Dell's download page requires. Current Dell Command | Update versions won't install without it.
