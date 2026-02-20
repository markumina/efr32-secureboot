# Secure Boot Flashing Script (Example)

This repository contains a simple example secure boot flashing script for Silicon Labs EFR32 Series 2 parts.

The script was tested using the SoC Door Lock Keypad sample application on an EFR32ZG23 high-security part.

## Usage

Run the main flashing flow from the project directory:

```bash
./myscript.sh
```

## Service menu (`-m`)

The script includes a service menu for controlled debug workflows:

```bash
./myscript.sh -m
```

Menu options:

- `1` Unlock debug + mass erase.
- `2` Flash without lock (leaves device unlocked for debugging).
- `q` Quit.

Use the service menu carefully. These options are intended for service/lab use and can change device security state.

## Binaries layout and required file names

The script expects firmware files under `binaries/` with a version folder and a variant folder.

`0.0.11` and `0.0.12` are example version names; your version directory names can be anything. Empty directories are fine for extra test menu items, as long as those items are not selected for flashing.

What cannot change is the required `.s37` naming for the selected paths. The script validates exact file names and locations before flashing:

- bootloader image must be named `secureboot.s37`
- application image must be named `brd-xg23-20dbm.s37`

If either filename is different (or in the wrong selected folder), the script stops at required-file checks.

Example structure:

```text
binaries/
	0.0.11/
	0.0.12/
		secureboot.s37
		staging/
			brd-xg23-20dbm.s37
			nextversiontest/
				brd-xg23-20dbm.s37
				secureboot.s37
```

Required file names:

- `secureboot.s37` (required in the selected version folder and selected variant/update folder)
- `brd-xg23-20dbm.s37` (application image in the selected variant folder)

For your current tree (`VERSION=0.0.12`, variant `staging`), the script expects:

- `binaries/0.0.12/secureboot.s37`
- `binaries/0.0.12/staging/secureboot.s37`
- `binaries/0.0.12/staging/brd-xg23-20dbm.s37`
- update files under the selected update directory (`staging/nextversiontest`)

