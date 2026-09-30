# Deploying AL-Mohanad fonts to domain computers with Group Policy

Goal: `al-mohanad.ttf` and `AL-Mohanad-Bold-1.ttf` installed **per computer**, so that
**every user** who logs on to those machines can pick the fonts in Word, Excel,
PowerPoint, Outlook, Photoshop, browsers — anything.

## How a "font for all users" actually works

Copying a `.ttf` into `C:\Windows\Fonts` is **not enough**. Windows only advertises a font
to applications when it is also registered under:

```
HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts
    "AL-Mohanad (TrueType)"  (REG_SZ) = "al-mohanad.ttf"
```

When you double-click a font and choose *Install for all users*, Explorer does both steps.
A GPO has to do both too. The **value name must match the font's internal name** (from the
font's `name` table), not the file name — `Install-DomainFonts.ps1` reads it out of the
file so you never have to guess.

Per-user installs (`%LOCALAPPDATA%\Microsoft\Windows\Fonts` + `HKCU\...\Fonts`) are the
thing to avoid here: they follow the *user*, not the computer, and they need no admin
rights. You want the HKLM route below.

## Files in this folder

| File | Purpose |
|---|---|
| `Install-DomainFonts.ps1` | Copies + registers every font in a folder, machine-wide. Idempotent, logs to `%WINDIR%\Temp\Deploy-Fonts.log`. |
| `Install-DomainFonts.cmd` | Wrapper to add on the GPO **Startup → Scripts** tab (sidesteps PowerShell execution policy). |
| `Uninstall-DomainFonts.ps1` | Removes the fonts + registry entries again. |
| `Uninstall-DomainFonts.cmd` | Wrapper for the uninstall script (edit the file names inside it if you rename the fonts). |

---

## Step 0 — prepare the font files (do this once)

1. Rename them to short, lowercase, space-free names. Spaces in `C:\Windows\Fonts` file
   names are legal but make every later command and GPP entry more fragile:

   | Original | Use |
   |---|---|
   | `al-mohanad.ttf` | `al-mohanad.ttf` |
   | `AL-Mohanad-Bold-1.ttf` | `al-mohanad-bold.ttf` |

2. Right-click each file → **Properties** → if there is an **Unblock** checkbox at the
   bottom, tick it and click OK. Files copied from a download or a USB stick carry a
   mark-of-the-web that can trip up later copies.

3. Note the exact internal names. From an admin workstation:

   ```powershell
   .\Install-DomainFonts.ps1 -SourcePath "I:\ad font" -ReportOnly
   ```

   It prints, per file, the `RegistryValue` / `RegistryData` pair it would create — e.g.
   `AL-Mohanad (TrueType)` = `al-mohanad.ttf`. You need these only for Option B; Option A
   works them out on each machine by itself.

4. Confirm the licence permits installing the fonts on every machine in the domain.
   Many Arabic display fonts are licensed per seat or for personal use only, and a GPO
   turns one download into a fleet-wide deployment.

---

## Option A — GPO computer startup script (recommended)

Works on any supported Windows client, handles the registry name automatically, logs what
it did, and self-heals if someone deletes a font locally.

### 1. Create the GPO

GPMC → your domain → **Group Policy Objects** → right-click → **New** →
`Computer - Deploy AL-Mohanad Fonts` → OK.
Right-click it → **Edit**.

### 2. Drop the payload into the GPO

In the editor:

**Computer Configuration → Policies → Windows Settings → Scripts (Startup/Shutdown)**
→ double-click **Startup** → click **Show Files…**

An Explorer window opens on the GPO's own SYSVOL folder:

```
\\corp.example.com\SysVol\corp.example.com\Policies\{GUID}\Machine\Scripts\Startup\
```

Copy **four** files into it:

```
Install-DomainFonts.ps1
Install-DomainFonts.cmd
al-mohanad.ttf
al-mohanad-bold.ttf
```

Keeping the fonts inside the GPO means there is no second share to create or secure, and
DFS-R replicates them to every DC along with the policy.

### 3. Register the script

Still in the **Startup Properties** dialog, on the **Scripts** tab (*not* the *PowerShell
Scripts* tab) → **Add…** → **Browse…** → select `Install-DomainFonts.cmd` → OK → OK.
Leave **Script Parameters** empty.

Why the `.cmd`: it launches PowerShell with `-ExecutionPolicy Bypass -NoProfile` and
passes `-SourcePath "%~dp0."`, so the script reads the fonts from the GPO folder next to
it. Using the *PowerShell Scripts* tab directly works only if your domain's execution
policy allows unsigned scripts.

### 4. Target the right computers

- **All computers in an OU** — link the GPO to that OU: right-click the OU →
  *Link an Existing GPO…* → pick the GPO.
- **Only some computers** — link the GPO higher up, then on the GPO's **Scope** tab under
  **Security Filtering** remove `Authenticated Users` and add a group holding the
  *computer accounts* (e.g. `GRP-Fonts-AlMohanad-Computers`). Because of MS16-072, also
  go to the **Delegation** tab → **Add…** → `Domain Computers` → permission **Read** —
  otherwise a filtered GPO can fail to read.
- Computer accounts pick up group membership only **after a reboot**, so a machine added
  to the filter group needs one restart before the policy even applies to it.

Close the editor.

### 5. Roll it out

A startup script runs at boot, so each target machine needs one restart:

```cmd
gpupdate /target:computer /force
shutdown /r /t 0
```

Or just let the machines reboot on their normal schedule. If you need the fonts *now* on
already-running machines without a reboot, see Option C.

### 6. Verify on a target machine

```cmd
dir %WINDIR%\Fonts\al-mohanad*
reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts" /f "*Mohanad*"
type %WINDIR%\Temp\Deploy-Fonts.log
gpresult /r /scope:computer
```

And from PowerShell, the same view an application gets:

```powershell
Add-Type -AssemblyName System.Drawing
(New-Object System.Drawing.Text.InstalledFontCollection).Families |
    Where-Object Name -like '*Mohanad*'
```

Then log on as any user and check the font list in Word. **An application that was already
running has to be restarted** before it shows a newly installed font — Office caches its
font list at launch.

---

## Option B — pure Group Policy Preferences, no scripting

Same end state, configured entirely in the GPMC UI. It refreshes with normal policy
(≈ every 90 minutes) instead of only at boot, but you must type the internal font names
yourself and you get no logging.

**1. Stage the fonts on a share every computer can read.** `NETLOGON` is the easy one —
on a DC create `C:\Windows\SYSVOL\sysvol\corp.example.com\scripts\Fonts` and copy both
`.ttf` files there. It is reachable as `\\corp.example.com\NETLOGON\Fonts` and its default
ACL already grants read to `Authenticated Users`, which includes computer accounts.

**2. Copy the files.**
**Computer Configuration → Preferences → Windows Settings → Files** → right-click →
**New → File**, once per font:

| Field | Value |
|---|---|
| Action | `Update` |
| Source file(s) | `\\corp.example.com\NETLOGON\Fonts\al-mohanad.ttf` |
| Destination file | `%WINDIR%\Fonts\al-mohanad.ttf` |

**3. Register them.**
**Computer Configuration → Preferences → Windows Settings → Registry** → right-click →
**New → Registry Item**, once per font:

| Field | Value |
|---|---|
| Action | `Update` |
| Hive | `HKEY_LOCAL_MACHINE` |
| Key Path | `SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts` |
| Value name | `AL-Mohanad (TrueType)` ← from `-ReportOnly`, must match exactly |
| Value type | `REG_SZ` |
| Value data | `al-mohanad.ttf` |

**4. Link and filter** the GPO as in Option A step 4, then `gpupdate /target:computer /force`
on a test machine and verify as in step 6. Users who were logged on during the copy will
see the font after signing out and back in (or restarting the app).

Caveat: the file copy silently does nothing if that font file is already open by a running
process. The startup script in Option A avoids this by running before any user session
exists.

---

## Option C — apply immediately, without waiting for a reboot

Add an **Immediate Task** to the same GPO so already-running machines install the fonts at
the next policy refresh:

**Computer Configuration → Preferences → Control Panel Settings → Scheduled Tasks** →
right-click → **New → Immediate Task (At least Windows 7)**

- **General** → Name: `Install AL-Mohanad fonts` → **Change User or Group…** → type
  `SYSTEM` → OK → select **Run with highest privileges**
- **Actions** → New → Start a program
  - Program: `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`
  - Arguments:
    ```
    -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "\\corp.example.com\SysVol\corp.example.com\Policies\{GUID}\Machine\Scripts\Startup\Install-DomainFonts.ps1" -SourcePath "\\corp.example.com\SysVol\corp.example.com\Policies\{GUID}\Machine\Scripts\Startup"
    ```
- **Common** → tick **Apply once and do not reapply**

Substitute your own domain and the GPO's `{GUID}` (visible in the address bar of the
*Show Files…* window from step 2). Keep the Startup script entry as well — it is what
makes the install survive re-imaging and self-heal later.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Font file is in `C:\Windows\Fonts` but missing from Office | The HKLM registry value is absent or its name doesn't match the font's internal name. Re-run `-ReportOnly` and compare, then restart the Office app. |
| Nothing happened at all | `gpresult /r /scope:computer` — is the GPO listed under *Applied Group Policy Objects*? If not, check the link, the security filtering, and that the computer has rebooted since joining the filter group. |
| Log file shows `Source not reachable` | The computer account can't read SYSVOL/NETLOGON. Test from the machine as SYSTEM (`psexec -s cmd`), then check the share ACL for `Authenticated Users` / `Domain Computers` read. |
| Log file shows `file is in use` | Harmless on a refresh — the installed copy stays and the replacement lands at the next boot, before user sessions exist. |
| Log file shows `Cannot open HKLM\... for writing` | The script isn't running elevated. Startup scripts run as SYSTEM; an Immediate Task must be set to run as `SYSTEM` with highest privileges. |
| No log file at all | PowerShell never started: AppLocker / WDAC policy, or you used the *PowerShell Scripts* tab with a restrictive execution policy. Use the `.cmd` wrapper on the *Scripts* tab. |
| Font appears but Arabic text renders wrong in Office | Not a deployment problem. Check the document's language and *Complex script* font settings in Word (Home → Font dialog → *Complex scripts* section), and that the font actually contains the Arabic glyphs you need. |
| One user still sees an old version of the font | They have a stale per-user install. Delete the font from `%LOCALAPPDATA%\Microsoft\Windows\Fonts` and its value under `HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts`. |
| Roaming-profile / RDS users | HKLM fonts are per machine, so each session host needs the GPO linked too. For a Citrix/RDS farm, apply this to the OU holding the session hosts. |

## Removing the fonts later

1. Put `Uninstall-DomainFonts.ps1` and `Uninstall-DomainFonts.cmd` into a GPO's
   **Startup** scripts folder (or the existing GPO, replacing the install entry) and add
   the `.cmd` on the **Scripts** tab. Edit the file names inside the `.cmd` first if you
   renamed the fonts.
2. Let every target machine reboot once, confirm via the log, then unlink and delete both
   GPOs. Removing the install GPO on its own does **not** uninstall anything — Group Policy
   scripts and GPP *Update* actions leave the files behind.
