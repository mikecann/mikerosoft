![header](docs/header.webp)

# ![](icons/page_copy.png) copypath

Copies the absolute path of a file, folder, or the current directory to the clipboard.


## Screenshots

![copypath screenshot](docs/ss1.png)


## Usage

```powershell
copypath              # copies current directory
copypath C:\some\path # copies the resolved absolute path
```

Works with relative paths, PowerShell provider paths, and paths that don't exist yet (falls back to resolving without checking).