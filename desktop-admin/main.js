const { app, BrowserWindow, shell, Menu, dialog } = require("electron");

const ADMIN_URL = "https://omkar3499.github.io/morya-agency-admin/?desktop=1";
let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1360,
    height: 900,
    minWidth: 900,
    minHeight: 650,
    title: "MORYA AGENCY Admin",
    backgroundColor: "#111827",
    autoHideMenuBar: false,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true
    }
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (url.startsWith("https://") || url.startsWith("http://")) shell.openExternal(url);
    return { action: "deny" };
  });

  mainWindow.webContents.on("will-navigate", (event, url) => {
    if (!url.startsWith("https://omkar3499.github.io/")) {
      event.preventDefault();
      if (url.startsWith("https://") || url.startsWith("http://")) shell.openExternal(url);
    }
  });

  mainWindow.loadURL(ADMIN_URL);
  mainWindow.on("closed", () => { mainWindow = null; });
}

app.whenReady().then(() => {
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { label: "MORYA AGENCY", submenu: [
      { label: "Refresh", accelerator: "Ctrl+R", click: () => mainWindow && mainWindow.webContents.reload() },
      { label: "Open Admin Website", click: () => shell.openExternal(ADMIN_URL) },
      { type: "separator" },
      { label: "Exit", accelerator: "Alt+F4", click: () => app.quit() }
    ]},
    { label: "Help", submenu: [
      { label: "About", click: () => dialog.showMessageBox(mainWindow, {
        type: "info",
        title: "About MORYA AGENCY Admin",
        message: "MORYA AGENCY Admin",
        detail: "Windows desktop wrapper. Requires an internet connection and the existing Supabase service."
      })}
    ]}
  ]));
  createWindow();
  app.on("activate", () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on("window-all-closed", () => { if (process.platform !== "darwin") app.quit(); });
