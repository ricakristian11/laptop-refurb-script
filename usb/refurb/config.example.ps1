# Refurb USB settings - edit before first use.
# Wi-Fi the laptops join during audit mode (for drivers, BIOS updates and activation).
# WPA2 networks only. Leave both blank if you'll plug in a USB Ethernet adapter instead.
# The script deletes this network from each laptop before resealing it for the buyer.
$WifiSsid     = ""
$WifiPassword = ""

# Battery health below this percent is flagged for disclosure in the listing.
$BatteryWarnPercent = 80

# How many rounds of Dell Command | Update to run (BIOS updates often need a 2nd round).
$DcuRounds = 2

# Debloat: Microsoft apps removed for every future user (the buyer included).
# They can all be reinstalled from the Microsoft Store if a buyer wants one.
# Kept on purpose: Store, Edge, Photos, Camera, Calculator, Notepad, Paint, Snipping Tool,
# Clock, Media Player, Terminal, Quick Assist, Windows Security, OneDrive, Copilot.
# Add "Microsoft.Copilot" below if you want Copilot removed too.
$RemoveApps = @(
    "Clipchamp.Clipchamp",
    "Microsoft.BingNews",
    "Microsoft.BingWeather",
    "Microsoft.BingSearch",
    "Microsoft.GamingApp",
    "Microsoft.GetHelp",
    "Microsoft.MicrosoftOfficeHub",
    "Microsoft.MicrosoftSolitaireCollection",
    "Microsoft.OutlookForWindows",
    "Microsoft.People",
    "Microsoft.PowerAutomateDesktop",
    "Microsoft.Todos",
    "Microsoft.WindowsFeedbackHub",
    "Microsoft.WindowsMaps",
    "Microsoft.549981C3F5F10",
    "MicrosoftCorporationII.MicrosoftFamily",
    "MSTeams",
    "MicrosoftTeams"
)
