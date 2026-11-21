Welcome to wland

Everything you see here runs inside a container: Chromium, this file
manager (PCManFM) and this text editor (l3afpad) are ordinary Linux apps.
They talk plain Wayland to a small relay, and the page in your browser is
the compositor that draws their windows.

Things to try:

  - Drag a titlebar to move a window, drag an edge to resize it.
  - Alt+F9 minimizes, Alt+F10 maximizes, Alt+F11 goes fullscreen.
  - Copy text in one app and paste it in another.
  - Browse the container's files; double-click a text file to edit it.
  - Reload the page: the apps start again (they don't survive a reload).

There is no terminal in this image. From your machine:

  docker exec -it <container> bash
  wland-run <app>          # inside: start any installed Wayland app

https://github.com/pithings/wland
