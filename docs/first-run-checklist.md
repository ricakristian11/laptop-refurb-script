# First-run checklist (test unit)

Run the kit on one laptop and tick each item. Anything unticked is a bug to fix before the batch.

## Before booting the USB
- [ ] `config.ps1` exists (copied from `config.example.ps1`) with your Wi-Fi name and password
- [ ] Dell Command | Update `.exe` is in `refurb/installers/`
- [ ] BIOS storage mode is *AHCI/NVMe*, Data Wipe completed and photographed
- [ ] Charger connected

## Install
- [ ] Windows Setup ran with no prompts (no language, edition, license or disk screens)
- [ ] It installed to the laptop's internal drive and the USB still has all its files afterwards
- [ ] The laptop restarted into Audit Mode (desktop as Administrator, no account-creation screens)
- [ ] The audit window opened by itself (if not, note what happened and start it manually)

## Script, stage 1
- [ ] Asked for the unit ID once
- [ ] Joined Wi-Fi ("Internet connection OK")
- [ ] Dell Command | Update installed and started applying updates
- [ ] If it restarted: it came back to Audit Mode and the script resumed on its own, in one window only
- [ ] `dcu-cli exit code` values look sensible (note them; 500 = nothing to install)

## Script, stage 2
- [ ] App removal listed what it removed; those apps are gone from Start
- [ ] Specs printed: service tag matches the sticker; CPU, RAM per slot, drive model/serial look right
- [ ] Battery % is plausible and `battery-report.html` opens
- [ ] "Activated: Yes"; BIOS license edition shows Professional
- [ ] Problem devices: none, or ones you can explain
- [ ] Screen test cycled through all colors and closed
- [ ] Keyboard test counted keys as you pressed them (including arrows, Tab, Print Screen)
- [ ] Speaker test played left, then right
- [ ] All QA questions accepted your answers

## Output on the USB
- [ ] `refurb/reports/inventory.csv` has one new row with every column filled
- [ ] `refurb/reports/<UnitID>_<ServiceTag>/` has `summary.txt`, `battery-report.html`, update logs and the transcript
- [ ] The CSV opens cleanly in your spreadsheet app

## Reseal
- [ ] Asked you to unplug the USB, waited, then ran sysprep
- [ ] The laptop shut down by itself
- [ ] **Next power-on starts normal first-time setup (region/keyboard screens), not Audit Mode**
- [ ] On that setup screen, your Wi-Fi network is not already saved
- [ ] Company-lock check on a phone hotspot: personal Microsoft sign-in screen appears

## After a full buyer-style setup (test unit only)
Complete setup once with a throwaway local account, then check and reseal again:
- [ ] Desktop has no Clipchamp, News, Solitaire, Teams (personal), Outlook (new) or other removed apps
- [ ] Windows Update runs and Windows Security shows no warnings
- [ ] No `C:\Refurb` folder and no `RefurbAudit` entry under the RunOnce registry key
- [ ] Device Manager shows no unknown devices
- [ ] To return it to sale-ready: run the BIOS Data Wipe again and boot the USB for a fresh install (resealing over a used account would leave that account behind)

## Note the timing
- [ ] Hands-on minutes for this unit: ____
- [ ] Total wall-clock minutes from USB boot to shutdown: ____
