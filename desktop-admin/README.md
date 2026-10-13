# MORYA AGENCY Admin — Windows 7 x64

This is a desktop wrapper for the existing hosted Admin app. It opens the current admin page and does not create, reset, migrate, or delete Supabase data.

## Important
- Internet access is required.
- This uses Electron 22.3.27 because Electron 23 and later do not support Windows 7. Electron 22 is end-of-life and has known security risks; use this only on a trusted computer and do not use it for general web browsing.
- The installer does not contain the Supabase database. Existing data remains in the current Supabase project.
- The .exe is not considered tested until installed and checked on the target Windows 7 64-bit computer.

## Build
Run the GitHub Actions workflow named **Build Windows 7 Admin EXE**. Download the generated workflow artifact named `morya-agency-admin-windows7-x64`.
