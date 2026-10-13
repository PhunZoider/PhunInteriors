# Adding PhunInteriors to an existing save

> **Use this at your own risk.** It deletes files from your save folder. I take
> no responsibility for a save that is damaged or lost by following it.
> **Back up your save by hand first**: copy the whole save folder somewhere
> safe before you touch anything, and do not rely on any other backup.

## The symptom

You enabled the mod on a save you already had, and going inside a vehicle puts
you in an empty patch of woods or bare ground instead of a room. A new game
with the same mods works.

## Why it happens

The rooms live on a map of their own, `phuninteriors`, in an empty area off
the edge of the normal world (cells 87,46 to 91,49). The map has to be in the
save's map list, ahead of `Muldraugh, KY`:

```
phuninteriors;Muldraugh, KY
```

If you went inside a vehicle before the map was in that list, the game sent
you to that area anyway. No map covered it, so the game made plain ground
there, and **Project Zomboid saves every piece of the world the first time it
loads**. From then on it uses the saved copy, not the map. Adding the map
later changes nothing for the parts that were already saved.

Copying those cells across from a save that works does not fix it either. A
save only holds the parts of the world its own player has loaded, so the copy
brings over some rooms and leaves the rest as woods.

The fix is to delete the saved copy of that area, so the game builds it again
from the map the next time it loads.

## The fix in single player

1. **Make sure the map is in the save's map list**, as above. If it is not,
   none of the rest helps.
2. **Quit to the main menu.** The game writes everything around you back to
   the save as it closes, so anything deleted while you are in the world is put
   straight back.
3. **Back up your save.** Saves are in
   `%USERPROFILE%\Zomboid\Saves\<game mode>\<save name>`. Copy that whole
   folder somewhere else.
4. **Open PowerShell**, change the first line to your save's folder, and paste
   the whole block straight into the window. Pasting it works; saving it as a
   `.ps1` file and running that is blocked by Windows' default settings.

   ```powershell
   $save = "$env:USERPROFILE\Zomboid\Saves\Sandbox\YOUR_SAVE_NAME"
   $cells = @(); foreach ($x in 87..91) { foreach ($y in 46..48) { $cells += "$($x)_$y" } }
   foreach ($x in 89..91) { $cells += "$($x)_49" }
   foreach ($c in $cells) {
     "chunkdata\chunkdata_$c.bin","metagrid\metacell_$c.bin","apop\apop_$c.bin","zpop\zpop_$c.bin" |
       ForEach-Object { Remove-Item (Join-Path $save $_) -ErrorAction SilentlyContinue }
   }
   Get-ChildItem "$save\map" -Directory | Where-Object { $_.Name -match '^\d+$' } | ForEach-Object {
     $cx = [math]::Floor([int]$_.Name / 32)
     Get-ChildItem $_.FullName -Filter *.bin | Where-Object { $_.BaseName -match '^\d+$' } | ForEach-Object {
       $cy = [math]::Floor([int]$_.BaseName / 32)
       if ($cells -contains "$($cx)_$cy") { Remove-Item $_.FullName }
     }
   }
   ```

5. **Load the save.** If you were standing in the woods, you should now be in
   a room. Leave through the door as normal.

## On a dedicated server

It is the same problem and the same fix. A server keeps its save in
`Zomboid/Saves/Multiplayer/<server name>`, where the server name is the name
of its `.ini` (`servertest` unless it was changed), and the map list is the
`Map=` line in `Zomboid/Server/<server name>.ini`. Where `Zomboid` sits
depends on your host: look for the folder holding `Server` and `Saves`.

1. **Check the `Map=` line** has `phuninteriors;Muldraugh, KY` (other maps
   can sit in the list too, as long as `phuninteriors` comes before
   `Muldraugh, KY`).
2. **Stop the server.** Everybody logging out is not enough: the server
   writes every loaded chunk back to the save as it shuts down, so anything
   deleted while it runs is put straight back.
3. **Back up the save folder.** Download the whole of
   `Saves/Multiplayer/<server name>` and keep it until you know the fix
   worked.
4. Delete the files, using one of the two ways below.
5. Start the server.

### If you only have FTP

FileZilla and most host file managers cannot do this in one go: the files are
spread across 160 folders. [WinSCP](https://winscp.net) (free, Windows) can,
from a script. First build the script: open PowerShell in a folder you can
find again, change the first two lines, and paste the block straight into the
window:

```powershell
$server = "ftp://YOUR_USER@YOUR_HOST:21/"
$remote = "/Zomboid/Saves/Multiplayer/servertest"
$out = @("option batch continue", "option confirm off", "open $server")
$cells = @(); foreach ($x in 87..91) { foreach ($y in 46..48) { $cells += "$($x)_$y" } }
foreach ($x in 89..91) { $cells += "$($x)_49" }
foreach ($c in $cells) {
  foreach ($f in "chunkdata/chunkdata_$c.bin","metagrid/metacell_$c.bin","apop/apop_$c.bin","zpop/zpop_$c.bin") {
    $out += "rm `"$remote/$f`""
  }
}
foreach ($cell in 87..91) {
  foreach ($cx in ($cell * 32)..($cell * 32 + 31)) {
    $d = "$remote/map/$cx"
    foreach ($y in 1472..1479) { $out += "rm `"$d/$y.bin`"" }
    foreach ($t in 148..155) { $out += "rm `"$d/$($t)?.bin`"" }
    if ($cell -le 88) { foreach ($y in 1560..1567) { $out += "rm `"$d/$y.bin`"" } }
    else { foreach ($t in 156..159) { $out += "rm `"$d/$($t)?.bin`"" } }
  }
}
$out += "exit"
$out | Set-Content "pi-reset.txt" -Encoding ascii
```

- `$server` is your FTP login, from your host's control panel. Use `ftps://`
  or `sftp://` instead of `ftp://` if that is what your host gives you, and
  change the port to match. Leave the password out: WinSCP asks for it.
- `$remote` is the save folder **as your FTP client shows it**, starting from
  the folder you land in when you log in. Open it in any FTP client first and
  copy the path, because hosts lay this out differently.

That writes `pi-reset.txt`, about 3,500 lines. Then run it from the same
folder:

```powershell
& "C:\Program Files (x86)\WinSCP\WinSCP.com" /script=pi-reset.txt
```

It sends one delete per line, so expect it to take a few minutes. Most lines
print an error saying there is no such file, and that is normal: the script
asks for every file that could exist, and your save only has the ones the
game actually wrote.

### If you have a shell (SSH)

Change the first line to the save folder on the server and paste the rest:

```sh
SAVE="/home/YOU/Zomboid/Saves/Multiplayer/servertest"
cd "$SAVE" || exit 1
for x in 87 88 89 90 91; do for y in 46 47 48 49; do
  if [ $y = 49 ] && [ $x -lt 89 ]; then continue; fi
  c=${x}_$y
  rm -f chunkdata/chunkdata_$c.bin metagrid/metacell_$c.bin apop/apop_$c.bin zpop/zpop_$c.bin
  for cx in $(seq $((x*32)) $((x*32+31))); do
    [ -d map/$cx ] && (cd map/$cx && rm -f $(seq -f '%g.bin' $((y*32)) $((y*32+31))))
  done
done; done
```

## What it touches

Only the interior area, which is off the edge of the normal map, so nothing
in the rest of your world changes. Nothing of yours was ever stored there,
because the rooms did not exist in that save until now.

Do **not** delete `global_mod_data.bin` while you are in there. It holds every
mod's saved data, not just this one's, and it is where your vehicles' rooms
are recorded.

Cells 87,49 and 88,49 are left alone on purpose: they belong to PhunTaxi and
PhunRooms. If you use either of those and had the same thing happen there, add
`"87_49"` or `"88_49"` to `$cells` before you run it. That covers the single
player script only. The two server scripts skip those cells by their own
arithmetic, so for those ask for help rather than editing them.
