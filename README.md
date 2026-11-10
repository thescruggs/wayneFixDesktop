# Fix OneDrive Long Paths

OneDrive will not sync a file when its full path (folders + file name) is longer than 400 characters. This script scans your Desktop, lists any files that are over the limit, and shortens their file names once you approve.

## How to run it

### 1. Open PowerShell

1. Click the **Start** button (or press the **Windows** key).
2. Type **PowerShell**.
3. Click **Windows PowerShell** in the results.

A blue or black window with a blinking cursor opens. You do not need to run it as administrator.

### 2. Copy this command

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/thescruggs/wayneFixDesktop/main/Fix-OneDriveLongPaths.ps1)))
```

Hover over the box above and click the copy button in its top-right corner, or select the whole line and press **Ctrl+C**.

### 3. Paste it and press Enter

1. Click inside the PowerShell window.
2. Press **Ctrl+V** (or right-click in the window) to paste.
3. Press **Enter**.

### 4. Review and approve

The script lists every file that is too long, showing its current name and the shorter name it proposes.

- Type **Y** and press **Enter** to rename the files.
- Press **Enter** on its own (or type anything else) to cancel. Nothing is changed.

If it says `No files exceed the 400 character limit`, there is nothing to fix and you can close the window.

## What it changes

- Only file names are shortened. The file type (`.docx`, `.xlsx`, and so on) is kept, and the file contents are not touched.
- Folders are never renamed. If a file sits inside folders whose names alone use up the limit, it is listed under "CANNOT be fixed" and you will need to shorten or move those folders yourself.
- A log of every rename (old name and new name) is saved to your user folder as `OneDriveLongPathFix_<date>_<time>.csv`. The script prints its location when it finishes.

## Just look, don't change anything

To see the list without being asked to rename anything, use this command instead:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/thescruggs/wayneFixDesktop/main/Fix-OneDriveLongPaths.ps1))) -ReportOnly
```

## Options

| Option | What it does |
| --- | --- |
| `-ReportOnly` | Lists the files and proposed names, then stops. |
| `-Path "C:\Some\Folder"` | Scans that folder instead of the Desktop. |
| `-MaxLength 400` | Changes the length limit. |
| `-MinBaseLength 8` | The shortest file name the script is allowed to produce. |

Add options to the end of the command, as in the `-ReportOnly` example above.
