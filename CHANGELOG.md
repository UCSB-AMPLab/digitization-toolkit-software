# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog, and this project uses pre-1.0 semantic versioning.

## [0.3.0]

This release adds unit modes, which decide what a unit sends outside, and pairing a unit with Fisqua from Settings. It adds Fisqua's queue to Queue, openings and pages that were never captured, a step that records which camera photographs which page, and a check of the cameras. It adds Canon PowerShot A2500 bodies under CHDK, with RAW+JPEG capture on them and on the T7. It adds a Network section to Settings and a testing space with its own account. Operators can free space on the card, and Captua keeps a reserve for its own work. An administrator can set a user's password, and everyone can change their own. The browser session moves into a cookie, so everyone signs in again after the update. A new unit is set up from its own screen with a wizard, a unit can ask for color card shots for each volume, an admin chooses the kind of camera in Settings, and each capture carries an id, so that a capture that timed out is neither lost nor taken twice.

### Unit modes
- **Unit mode** in Settings lets an admin choose one of three modes: **Scanner only**, **Offsite copy only** or Fisqua.
- In **Scanner only**, Captua copies nothing to the bucket and makes no call to Fisqua. In **Offsite copy only**, Captua copies the images and the catalog to the bucket and makes no call to Fisqua. In Fisqua mode, everything is on. Switching to a lower mode changes no data. Handovers queued at that moment go out after the unit returns to Fisqua mode.
- At the first start after the update, Captua sets the mode the unit's configuration allows. Fisqua mode needs the offsite copy of the images, the offsite copy of the catalog with a valid recipient, and the Fisqua link. **Offsite copy only** needs the first two. A unit with less starts in **Scanner only**.
- A switch is refused, with the reason for each problem, when its prerequisites are missing. **Offsite copy only** needs the offsite copy and a catalog copy with a valid recipient. Fisqua mode also needs the link and a reachable Fisqua. Leaving Fisqua mode asks for confirmation.
- Projects are hidden on every unit after the update, including units that already have projects. An admin can show them with **Use projects**, in **Scanner only** only. While they are hidden, the side menu has **Volumes** in place of **Projects**: one list of every volume, searchable by title, stem and reference code, and filterable by stage. A new volume goes into the unit's default project.
- In Fisqua mode, operators cannot create volumes, change a stem or a reference code, or import a list. An admin can. Captua checks each reference code an admin gives with Fisqua and refuses one Fisqua does not know.
- A volume can be kept on the unit: Captua does not copy its images to the bucket or send it to Fisqua until an admin includes it.
  - Volumes created in **Scanner only** are kept.
  - In any mode, an admin can keep a volume with **Keep on this unit**, a box meant for test volumes, as long as no file of the volume has left the unit and it has not been sent to Fisqua.
  - Keeping and including apply to the volumes inside a volume.
  - Leaving **Scanner only** lists the kept volumes and asks whether to include them or keep them on the unit.
  - The records of a kept volume still go to the bucket with the daily catalog copy in **Offsite copy only** and in Fisqua mode. Its images stay on the unit.
- The volume lines and the offsite and catalog boxes in Settings say where Captua keeps the images and the catalog in the current mode. In **Scanner only**, the catalog shows **Catalog on the scanner only** and is not marked late or overdue. The Fisqua box is hidden in modes that do not use the link.
- In Fisqua mode, when an admin creates a volume with **Keep on this unit** unticked, the stem field searches Fisqua's descriptions once three characters are typed.
  - It lists up to 20 matches, each with its code, dates, level and full title.
  - Choosing a match fills the stem, and fills an empty name from the title.

### Pairing a unit with Fisqua
- An admin can link a unit to Fisqua from Settings, in **Connect to Fisqua**. The admin names the unit and gets a six-character code, and a workspace admin approves the code on the **Scanner** page in Fisqua. Before, the link was set up by running the provisioning script `provision-rclone.sh` on the unit.
- After the approval, Captua writes the link settings and restarts. The card warns about the restart, shows the code, the time left and each refusal, and keeps polling the unit until Captua answers again.
- Pairing is possible in Fisqua mode, or in **Scanner only** if the unit has no link yet. A linked unit can pair again only with the same workspace. Pairing does not change the mode. It is refused while a capture or an offsite job is running. The unit pairs with production Fisqua unless `FISQUA_ENV` says staging.

### Queue and Fisqua's queue
- In Fisqua mode, Queue lists Fisqua's queue for the unit, first among the lists. An operator sees their own items and the unassigned ones. An admin filters by **Mine**, **Unassigned** or **Everyone**. Each item names its assignee. Withdrawn items are not shown. A spot recapture lists its pairs.
- Queue groups the items still to do in three sections: **First: finish what's in progress**, **Second: recaptures and rescans** and **Third: new material**. **Next** follows the order of the sections. An item whose volume still has retakes stays in the second section even when it is marked finished. **Mark as done** is now **Mark as finished**.
- On a spot recapture, each pair shows its sequence, and the page when Fisqua names one side, in place of the volume's title.
- An operator can start capturing a volume whose list item asks for a full rescan in any turn. Sending a rescan to review for the first time allows one new volume. Turns still do not accumulate.
- A record Fisqua excluded shows **Excluded**, with its own count on the volume's status bar and Fisqua's reason.
  - It is not pending, it is not a retake, and it does not block the handover.
  - Approving, rejecting and retaking are not offered. Only an admin can delete it.
  - The export leaves it out.

### Working with Fisqua
- The capture manifest is written as version 1.9 in every case. `CAPTUA_FISQUA_ROTATE_DEG` now decides only whether each image carries `rotateDeg`. Before, the manifest was version 1.1, or version 1.5 with that setting on. Use this release only with a Fisqua that reads contract 1.9.
- Each call to Fisqua closes its connection when it ends. Before, every call opened a connection and none was closed.
- When Fisqua asks Captua to wait after a status check, the line says so. Before, it read "Captua asked Fisqua about no volumes".

### Retakes and missing pages
- An opening with only one page photographed is shown with the missing side marked **Page not captured**, and Captua asks for a recapture.
  - The record counts as pending from the start.
  - In **To retake**, its row names the missing page, as odd/recto or even/verso, and says to capture the whole pair again.
  - It does not block the rest of its volume from being sent.
- An opening that was never captured is shown as a placeholder: two empty pages under a dashed frame, with the label **Opening not captured**. Operators and admins can mark an opening as missing from the toolbar or from the gap between two tiles.
- **To retake** is grouped by volume, in each volume's order. Placeholder rows offer **Capture** and "No opening here". Missing-page rows offer "No page here".
  - A record can be closed without capturing, for one of four reasons: a skip in the foliation, a leaf missing from the volume, captured elsewhere, or other. Other needs a note.
  - A closed record turns gray, shows **Closed** and its reason, and is no longer pending.
- Capturing into a placeholder shows where the capture goes, between its neighbours, and the note from Fisqua's review. After the capture, **Capture another here** inserts the next opening after it, and **That was the last one** moves the guide on.
- Before a volume is sent, Captua refuses a record that has an image on a side marked missing.
- The retake window shows thumbnails first. **View full size** shows the full-size image, with pan and zoom, and **View thumbnails** returns to the thumbnails. The guided retake loads the thumbnails of the next two pending records ahead of time.
- A retake of an opening with two cameras sends the camera swap. Before, a unit whose cameras were swapped recorded the retaken pages the wrong way round.
- The retake band on the overview says the records were rejected in review or not captured in full, and that the turn is per volume. It said the digitization list asked for them to be captured again.

### Volumes digitized before Captua
- A line of a rebuild bundle's `images.jsonl` can name the bucket of its source image: `zasqua-transition` or `zasqua-preservation`. Any other value is refused. A line without it names `zasqua-transition`, as before.
- A bundle's `plan.json` can carry `indexOffset`, from 0 to 9999. The rebuilt volume's files are then numbered after the records they replace, so no bucket key is reused.
- A plan record can mark an opening with one image as missing a side, with `{"mode": "dual", "missingSide": ...}`.

### Moving captures into the volume Fisqua assigned
- An administrator can move the captures of a volume made by hand into the empty volume that Fisqua assigned. Captua renames the files, moves the records and the color card shots, and uploads the files again under the new names.
- If the move is interrupted, Captua finishes it or undoes it when the unit next starts. If it can do neither, an administrator can ask Captua to fetch the missing file again from the offsite copy and settle the move.
- The emptied volume takes no new captures and can be deleted.
- An administrator starts the move from the hand-made volume's page: Captua shows the plan, or each reason the move cannot run, before anything changes.
- If the answer to a move is lost, for example on a slow connection, Captua asks the unit what became of it and shows that. It does not offer a second move until the first is settled.
- A notice on the Overview and on the two volumes tells administrators when a move was interrupted and could not be finished or undone. Repair fetches the missing file from the offsite copy and settles the move.

### The Overview
- The Overview is rebuilt for the unit's own screen and for a large monitor: one column on the unit, two on a monitor.
- A "Needs attention" block lists what needs someone: a camera that is not detected or cannot capture, cameras of another kind than the unit is set up for, storage that is nearly full, and volumes with retakes.
- The camera preview and the "Focus" and "Test" buttons are no longer on the Overview. They are in the camera check. Press "Check cameras" to open it.
- The storage notice says how much space can be freed.

### Cameras and set-up
- Cameras are named by where each stands, **Left camera** and **Right camera**, and pages by **odd/recto** and **even/verso**. The left camera photographs the odd/recto page. Every image of a page shows both names, in short form where space is small. Before, the interface called the pages left and right and named each camera after its page, so "left camera" was the camera on the right.
- When a new camera body is connected, a body is moved to another USB socket, or a camera's page is unconfirmed or in conflict, Captua shows **Which image is the odd/recto page?** over the capture screen. After the update, every unit shows it until its cameras are confirmed.
  - The step shows a current frame from each camera. The operator presses the image of the odd/recto page and can turn an image that is sideways or upside down.
  - It cannot be dismissed until the question is answered, and capture is refused until then. **Leave the capture screen** goes where the back button goes.
  - If Captua cannot identify a camera, the step says an admin has to set that camera up, and no one can capture until then. If fewer than two cameras are connected, it asks for both to be connected and offers **Reconnect cameras**.
  - After both pages are confirmed, they decide which camera is left and which is right, and the swap control is hidden.
  - **Check cameras** has an option, **Change the page of each camera**, to change which camera photographs which page.
- **Check cameras** opens from the capture screen. It takes test captures from both cameras and shows each with its saved orientation. Captua does not save test captures to the volume.
  - A pane can be turned 90 degrees clockwise, and Captua saves the orientation.
  - For cameras with stepped zoom (PowerShot A2500 under CHDK), one linked control sets the zoom of both, with **Adjust separately** and **Match** while the two differ. For cameras with a zoom ring, each camera's focal length is shown, with a notice when the two differ.
  - **1:1** shows both captures at full size under one zoom and pan.
  - A chip for each camera in the top bar shows whether Captua can reach it, and the model and connection are in its details.
  - The button is disabled while a capture is in progress.
- On Canon DSLR bodies, **Refocus** opens a dialog in three stages: the lenses to AF, test captures checked at full resolution, and the lenses back to MF.
  - Captua opens the dialog on the first visit to the capture screen after signing in, and after 15 minutes without a capture or a focus check, when no other dialog is open. It can be skipped.
  - The pedal and the capture key take the test pair and never start a real capture while the dialog is open.
  - A test capture is limited to 20 seconds and is never saved. The focal length is shown under each one.
  - A camera that could not focus gets a list of what to check.
  - **Continue** waits until both lenses read MF, and **Continue anyway** is offered after two failed readings.
- A camera whose orientation was never saved takes a default from its page: 270 degrees for the camera that photographs the even/verso page and 90 degrees for the camera that photographs the odd/recto page, and 90 degrees when the camera has no stored page. The default applies on the capture screen, in the default capture settings and in the device list, and the capture screen applies it as soon as the pages are saved. Saved orientations and stored captures do not change.
- When a gphoto2 camera is connected but sends no image, the capture screen and the overview say "The camera is connected but is not sending an image" and tell the operator to turn the camera off and on again, and to unplug and replug its USB cable if that does not help. Captua shows the notice 30 seconds after the first answer without an image. Before, the camera was shown as not connected. The backend tries a failed frame once more, and closes the camera's session after ten seconds of failed frames.
- Captua works out which kind of camera a unit has from what is connected: Pi cameras, Canon DSLR cameras or Canon A2500 cameras (CHDK). An admin can choose the kind in **Settings › Cameras**, or go back to detection. A change that needs it restarts Captua, after a confirmation. `CAMERA_BACKEND` is still read when it is set, and a choice made in Settings comes before it.
- When the connected cameras are of another kind than the one the unit is set for, the capture screen says so and tells the operator to ask the admin. Diagnostics lists the kind in use, why, the drivers installed and what is connected.
- After the backend stops in the middle of a capture, a Canon body that does not open gets one USB reset and one more attempt, with no action by the operator. The reset goes to that body's own USB socket. On the bench it recovered a camera without anyone acting.
- Canon bodies are opened one at a time. Right after a body is opened, Captua discards the events the camera had queued for the process that stopped; a file announced among them is never taken as a page, and is not fetched or deleted.
- Messages about a Canon body name the camera by its number, and by **left** or **right** when the unit knows it, and say what to do at the unit: wait and try again, switch the camera off and on, or ask the admin.
- When a camera's image is turned 180 degrees from the default of its page, a notice says that the two cameras' pages are probably swapped and offers the camera step. **Check cameras** says which page the image marked odd/recto must show.

### Color card shots
- A unit can ask for a photograph of a color card with each camera, so that a volume's colors can be corrected later. The capture screen asks before a volume's first page, for a volume that already has pages and no shots, and after the ISO, shutter speed, aperture or zoom step of a camera is changed.
- The step takes one shot per camera, shows each, and offers **Take again**. **Skip** records that the shots were skipped, after one confirmation. No page can be captured while shots are needed.
- An admin turns the asking on and off with **Ask for color card shots** in **Settings › Cameras**. It is off on a unit that updates to 0.3.0, and on for a unit set up with 0.3.0.
- Shots are kept in the volume's `calibration` folder, outside the page sequence: page numbers, pairs, review and retakes are unaffected. They go to the offsite copy and to Fisqua with the volume, and are counted by export, by the free-space check, by freeing space and by the integrity check.
- A volume that lacks its shots carries a flag in the lists of volumes and on its own page, where admins and operators can open the list of its groups of shots, with each group's delivery to the offsite copy.
- On a camera set to automatic exposure, Captua cannot tell that the exposure changed, and does not ask again for that reason.

### The capture screen
- On a unit that cannot show a continuous preview (T7 through gphoto2, A2500 through CHDK), the capture screen shows one frame per camera on entry and the pair just captured after each capture. **Refresh preview** fetches one frame per camera on request, and waits while a retake or a capture from the image window is in progress. Each pane is labeled **Last capture** or **Preview (not saved)**.
- The capture key is assigned in Settings, in **Capture key** (see Settings and the network). It is no longer in **Grid and guides**.
- With no key assigned, the space bar and `b` both start a capture. The foot pedal the project uses sends `b`. Assigning a key replaces both defaults, and Reset restores them. Letter case is ignored, so Caps Lock does not disable the pedal.
- Camera orientation that fails to save is reported under the viewer, with the camera's name and a retry. Before, the failure went only to the console and the next visit showed the earlier orientation.
- Captua records the camera model with each capture. A T7 is recorded as "Canon EOS Rebel T7". Before, every capture recorded "CameraConfig". Rows already written keep it.
- A capture that takes longer than 10 seconds shows a line saying the camera is taking longer than usual and to wait. When the request gets no answer in time, the screen keeps every capture control locked and reads the volume's records again every 5 seconds, for up to 3 minutes, and then says either that the capture was saved or that none was. Before, it showed an error and freed the controls while the backend went on to store the capture, so a second press made a duplicate.
- While any capture or test capture is running or being checked, no other can start, from the button, the pedal, the image window, **Capture another here**, **Check cameras** or **Refocus**. Thumbnails cannot be opened during a capture.
- No capture can start until the volume's records have been read. If that read fails, the screen says so and offers **Retry**.
- Each capture carries an id that the screen generates. When a capture request times out, the screen asks the unit about that capture and reports that it was saved, that it was not saved, or that Captua could not find out. A capture reported as not saved cannot be stored afterwards, so capturing again cannot make a duplicate.
- When Captua cannot find out, the message names what to check for that kind of capture. The screen reads the volume's records again before it allows a capture, and blocks capture with **Retry** if that read fails. It keeps asking about the capture in the background for up to 15 minutes. A capture found saved that way updates the records, the last capture and the images, and moves nothing on the screen.
- The capture screen opens in the mode of the volume's last record: one camera or two. An empty volume opens with two cameras. A retake or a fill is sent in the mode of the record being retaken.
- The camera panel remembers, in the browser, whether it is open and which of its sections are open.
- The capture screen opens with no volume, to check the cameras. In that view it shows the preview and **Check cameras**, has no capture button, and the capture key captures nothing. The Overview links to it for admins and operators.
- A button beside the capture button retakes the last opening captured or retaken on this screen, after a confirmation. Captua reads the volume again first and retakes only if the record is unchanged; if it was changed on another screen, the screen says so and retakes nothing.
- A capture writes to the notice at the top only while it is the latest capture started and the screen is still on the same volume. Before, a capture that finished late could clear a later capture's error.

### Canon PowerShot A2500 bodies (CHDK)
- Captua keeps A2500 bodies awake and in shooting mode through a session.
  - It sends the camera `enter_alt()` before switching it to shooting mode, before every capture, and at most every 30 seconds while previews run. If the camera stays in playback after the switch, Captua sends a half-press of the shutter and waits up to 4 seconds.
  - Every minute, each open body with no other request gets one small read that changes no mode or setting.
  - With Canon's "Auto Power Down" on, an idle body switched itself off after three to five minutes in the tests that led to this change.
- Captua sets the zoom of an A2500, which has 64 steps and no ring. Captua stores the step a camera confirmed for that body and applies it each time the body enters shooting mode.
- Each time an A2500 is opened and reaches shooting mode, Captua compares its clock with the unit's local time and sets it when they differ by more than 5 seconds.
- A capture is accepted only when the picture is whole. Otherwise the capture fails and nothing is written. Captua does not send a script to the camera while another is running.
- A capture or preview that finds its body gone from the bus scans once and runs once more, only when the body at that index is the same camera.

### Capture formats
- The format selector offers **JPEG** and **RAW+JPEG** on every camera that reports formats: T7 bodies and A2500 bodies under CHDK. A T7 that reports RAW or RAW + L is shown as RAW+JPEG. There is no RAW-only format.
- A line under the selector says what each choice stores.
  - On a T7, RAW+JPEG stores one CR2 with the JPEG inside it, which Captua copies out as the preview.
  - On an A2500, it stores a DNG in `captures/` as the master and the camera's JPEG of the same exposure in `previews/` as `<name>_preview.jpg`. Captua stores nothing unless both files are whole.
  - With JPEG, only a JPEG is stored.
- The format is stored for each camera body on the unit, on the T7 as well as the A2500, and is kept when the backend restarts. Captua sets it on a T7 when the camera's session opens, and before a capture when it differs from the format last set. A capture whose file type differs from the format is logged, and the next capture sets the format again. A change the camera does not confirm is refused, and Captua sets the camera back. Before, the selector changed only the camera's own setting and dropped a refused value without an error.
- The option that made a T7 write a second, separate JPEG is removed.
- The shutter and ISO lists appear only for cameras that take them. An A2500 was offered the lists meant for the Pi camera modules.
- The lens-switch note and the autofocus warning in the Focus panel show only for DSLRs. An A2500 has no lens switch.

### Settings and the network
- Settings is divided into sections, chosen from a list beside the page, or from a row of tabs on the unit's own 800×480 screen. **Network** and **Language** are open to every role. The administrator's sections are under **Unit**, and the Fisqua link is one of them.
- **Network** shows the unit's wired and Wi-Fi connections with their addresses, lists the Wi-Fi networks in range and the saved ones, and warns, with what to try, when the unit has no connection, no address or only a local address. The side menu shows the state of the connection.
- Admins and operators can join a Wi-Fi network with **Join**, and forget a saved one with **Forget**. A network can be open, have a password, or need an institutional account (user name, password and sign-in server name). The join dialog says that the password is saved on the unit and that anyone with administrator access to the unit can read it. Before, changing the Wi-Fi network needed a keyboard and the Pi's own desktop.
- A join can take the unit off the network the browser uses. The dialog follows the join, and says when the unit went back to its previous network, when it cannot tell how the join ended, and when it cannot reach the unit.
- On the overview, the storage warning links to **Storage** for admins. For other roles it tells them to ask the administrator.
- The storage note in Settings says that every new image goes to the active drive, including for volumes started on internal storage, and that drives should be switched only between volumes, because a volume in progress would have its images split across two disks. The Spanish text of that section is reworded.
- Settings has three more sections: **Cameras**, **Capture key** and **Language**.
- The capture key is a setting of the unit: the key or pedal assigned in **Capture key** works from every browser. Admins and operators assign it. A key that a browser had assigned before the update is carried over once, if the unit has none.
- Each person has a language, stored with their account and applied on any device they sign in from. **Language** in Settings sets it, and an admin sets the unit's language there. The sign-in page no longer has a language picker; it has a link to the credits.

### Storage
- Operators can free space on the card. They could not before, and at a unit whose only administrator is the project's own account, nobody on site could act when the card filled. Restoring a volume to the card stays with administrators.
- Settings › Storage is open to operators. It shows the usage figure, the space Captua keeps for itself, and **Volumes with space to free**: the volumes whose files are all verified in the offsite copy, from the most space to the least, each with a **Free space** button that opens the existing dialog. The drive controls stay with administrators.
- The storage warning on the overview sends administrators and operators to that list. A reviewer is told to ask an administrator or an operator.
- Captua keeps 2 GB free for its own work. The usage figure counts that reserve as used, so it reads 100% when only the reserve is left. A capture or an upload is refused before the reserve is used, with a message that says where to free space.
- On a unit that cannot read the offsite copy, a freed volume cannot be restored or exported from that unit. The dialog says so before the operator confirms, **Restore to the SD card** is not offered there, and the messages on a freed image and on a refused export say the same.

### The testing space
- An admin can switch on a testing space from **Testing** in Settings. It has one shared account with the role `testing`, for practising. The admin sets the account's user name and password, the number of days after its last capture before Captua removes a testing volume (1 to 365), and the free space in GB kept for real work (1 to 10000), and can empty the space with **Clear the testing space**.
- The testing account has its own projects and volumes, marked with a badge and with the date on which the unit removes each volume. It creates, renames and deletes them, captures, retakes and uploads. It has no review, handover, offsite, queue, export or camera set-up controls.
- Testing projects and volumes stay on the unit in every mode. Captua copies none of their images to the bucket and sends none of their manifests to Fisqua. They do not count for the recapture turn. No volume moves between the testing space and real work.
- Captua checks for expired testing volumes every hour and removes them with their records and images. A capture into a testing volume is refused when free space falls below the reserve.
- A testing project has a capture format, JPEG unless **RAW and JPEG** is chosen. Real project names, stems and reference codes cannot begin with the reserved prefix `captua-testing-`. The backend gives each testing volume its stem, and a testing volume has no reference code.
- The testing account can download a volume's pictures, and copy them to a USB drive with **Copy to USB drive**. The drive has to be an unmounted FAT32 or exFAT partition that shares no disk with the system or the projects. Each copy goes into a new folder, a copy that is running is found again after its dialog is closed, and the unit says when the drive can be removed.
- When a user signs out of the testing account, the sessions of the others who use it continue. Deactivating the account or changing its password ends them all.

### Setting up a new unit
- On a unit with no account, the screen attached to the unit opens a set-up wizard: the language, the first admin's account, then the network. At the unit itself no bootstrap token is asked for. From another device, the form with the token remains.
- The language chosen in the wizard becomes the unit's language, which the sign-in page uses.
- When creating the account gets no answer, the wizard checks whether an account now exists and signs in with the name and password just entered. If the unit has an account that is not that one, the wizard says so.

### Sign-in
- Captua keeps the sign-in in an httpOnly cookie instead of in the browser's storage and in addresses. A token an earlier version left in the browser is deleted, and the browser starts signed out. A page opened before the update shows no thumbnails, previews or downloads until it is reloaded.
- Signing out ends every session of that user, in every tab and on every screen, except for the testing account. Before, it cleared the cookie only in the browser that sent the request. Changing one's own password and deactivating a user end the user's sessions too.
- The interface renews the session while someone uses it (a pointer press, a key, a touch, a wheel turn, the pedal included), at most once every ten minutes and never on a timer, so a screen left alone still signs out. Before, a session ended eight hours after sign-in whatever the operator was doing.
- Every request from the interface ends after a time limit: 60 seconds by default, 15 for the health check, 150 for calls that wait on Fisqua, on files or on storage, and 300 for camera calls. Before, a request that nobody answered kept its screen waiting.
- An administrator can set another person's password from **Users**, with **Set password** in the row's menu. It ends every session of that person. Before, a forgotten password meant deleting the account and making a new one.
- Everyone except the testing account can change their own password from the account menu, with **Change password**. It ends all their sessions, and the sign-in page confirms the change.
- A new password needs at least 8 characters, when a user is created, when an administrator sets one and when a user changes their own. Passwords set before the update still sign in.
- A wrong current password in **Change password** counts against the same limit as a wrong password at sign-in.

### Other changes
- The Status column of the project list is removed. It showed one of five fixed labels chosen by the row's position, not a status read from the unit.
- The seedling with the Captua wordmark is Captua's logo on the welcome, sign-in and set-up screens and in the side menu, and the browser favicon is the small seedling.
- The guided tour follows the unit mode.
  - With projects hidden, step 1 is dropped, and step 2 is **Create a volume** on **Volumes**.
  - In Fisqua mode, an operator has five steps: **Choose a volume** in Queue; **Capture** beside the volume in Queue; sending to review; following the review, with the Fisqua status in the volume's top bar; and export. An admin has the steps for **Volumes**.

### Fixes
- After a start, the Overview no longer says that no camera is detected while the unit is still finding its cameras.
- On a volume's page, the row and the notice under the top bar now have their margins, the bar no longer cuts off its second status line, and the notice about an interrupted move shows its heading first.
- On the unit's screen in Spanish, the buttons in a volume's top bar overlapped. The title is now shortened to make room.
- Storage sizes are counted the same way on the Overview and in Settings, in the units that drives are labeled with. A disk that read 466 GB / 507 GB now reads 500 GB / 544 GB.
- An empty `CAPTUA_<X>` setting no longer hides `DTK_<X>`, and a bare `CAPTUA_X` line in an env file counts as unset. Before, an empty number or boolean setting stopped the backend from starting.
- The banners for a missing stem, a capture error and a lost connection are centered without halving their width. On the unit's narrow feed, the missing-stem banner wrapped a word per line.
- At 800x480, the floating controls on the capture screen fold into a grid, and every button stays on screen.
- Live settings changed within the same 200 ms are all sent, to the camera they were made for. Before, a pending change of another kind was dropped.
- Every button on the capture screen has an accessible name, including the grid and guide-line toggles.
- The gphoto2 backend logs a camera only when it is first detected, moves to another port, or is no longer detected. On a unit with two cameras, the log had reached its size limit in about an hour of capturing.
- The gphoto2 backend scans the USB bus only when its camera list may be out of date. Before, it scanned about 84 times a minute on a unit with two cameras and a live preview.
- When a project cannot be deleted because it still holds volumes or files, an admin reads the reason in the interface language, with the number of volumes and records. Before, the English sentence from the backend was shown in Spanish too.
- An error answer no longer repeats what was sent. A request with a missing or wrong field was answered with the values it carried, a password included.
- A database error no longer puts a statement's values in the log.
- A failed update could end as if it had succeeded and leave the previous version not restored. A `return` with no status in a function run from the script's exit handler took the status from before the handler on the Pi's bash 5.2. Every `return` in the scripts now states its status.
- A retake or a fill could be stored against a record whose images had changed since the screen read them. The request names the images it expects, and Captua refuses it if they differ.

### Installing and updating
- `update.sh` installs a polkit rule, `/etc/polkit-1/rules.d/40-captua-network.rules`, that lets the user `pi` scan, join and forget Wi-Fi networks through NetworkManager. It grants three actions and no others. **Network** uses it.
- `update.sh` reinstalls the system helper on every update. The helper has a new verb, `restart-backend`, which pairing with Fisqua needs.
- A unit updating from 0.2.0 does not receive the rule and the helper in that update, because `update.sh` keeps running its old copy after it pulls. Run `sudo scripts/install-network-permissions.sh` and `sudo scripts/install-system-helper.sh` once, or update a second time. Without the helper, a unit cannot pair with Fisqua.
- `provision-rclone.sh` can be run by the backend to pair a unit. `--replace-credential` moves the existing rclone configuration aside and restores it if the new one fails before `offsite.env` is published.
- `.env.example` lists every setting the backend reads, each with its default, and a test checks that none is missing.
- A stop or restart of `dtk.service` is no longer logged as a failure. A crash still restarts the unit. The change reaches a unit only when `scripts/install-service.sh` runs.
- nginx allows the two capture routes 300 seconds; every other route keeps 120. An update recreates the nginx container, so the new file is read.
- `DTK_STORAGE_RESERVE_GB` sets the space Captua keeps for itself, in GB. The default is 2, and 0 keeps none.
- From the second update to this version on, a unit shows a page saying that Captua is stopped for an update while `update.sh` or `rollback-update.sh` has the stack down, and an open screen reloads when Captua is back. On a short update the page covers only part of the time: on the bench, 4 of 18 seconds.
- When a unit stops answering for any other reason, a banner on every page says so after three failed checks and offers **Reload**. Captua does not reload the page for that.
- `.env.example` leaves `CAMERA_BACKEND` unset, so a new unit detects its cameras.

### For maintainers
- The README sets the HTTPS rewrite for GitHub before cloning, so a fresh Pi without a GitHub key can fetch the submodules.
- The guides, the developer pages and the API reference are at captua.org. The Quarto site and the wiki are removed from the repository.
- `scripts/stamp-versions.py` sets each file's `Version:` line at a release, from the changes since the previous release tag, and sets `VERSION`, `package.json` and `pixi.toml`. Nobody writes a `Version:` line by hand. `scripts/check-version-headers.sh` is removed.
- The frontend is formatted with Prettier, and CI checks the formatting. Run `npx prettier --write .` before pushing.

### For integrators
- `POST /collections/{source}/adopt-into/{target}` accepts `client_request_id`. `GET /system/adoption/requests/{id}` reports what became of that request. `GET /system/adoption` reports what holds the adoption lock, and the repair accepts `run_id`.
- New routes:
  - `GET` and `PUT /system/unit`
  - `GET /system/pairing`, `POST /system/pairing`, `POST /system/pairing/renew`, `DELETE /system/pairing`
  - `GET /cameras/setup`, `PUT /cameras/roles`
  - `POST /collections/{id}/records/missing-opening`, `POST /records/{id}/missing-page`, `POST /records/{id}/close-missing`
  - `POST /collections/{id}/release-from-unit`, `POST /collections/{id}/keep-on-unit`
  - `GET /fisqua/descriptions?q=`
  - `POST /auth/logout`
  - `POST /cameras/focus-lock/{i}` and `DELETE /cameras/focus-lock/{i}`
  - `GET /network/status`, `GET /network/wifi`, `GET` and `POST /network/wifi/join`, `DELETE /network/wifi/saved/{uuid}`
  - `GET` and `PUT /system/testing`, `PATCH /system/testing/account`, `POST /system/testing/clear`, `GET /system/testing/usb`
  - `POST /collections/{id}/usb-copy`, `GET /collections/{id}/usb-copy/status/{job_id}`
- An admin lists testing material with `space=testing`. Any other role, and an admin who does not ask, never sees it. A route that would move a record or volume between the testing space and real work answers 409 `cross_space`.
- The capture manifest declares contract 1.9 whatever the value of `CAPTUA_FISQUA_ROTATE_DEG`, which only decides whether each image carries `rotateDeg`.
- `POST /auth/login` with an `X-Requested-With` header answers with a cookie and no token in the body. A request authenticated by the cookie that is not `GET`, `HEAD` or `OPTIONS` needs `X-Requested-With` or is refused with 403. `?token=` is no longer read. A `*` in `CORS_ORIGINS` stops startup.
- `POST /cameras/test-capture/{i}` takes `focus_check=true` and `layout=true&page_side=left|right`. Its answer carries `X-Focal-Length` and `X-Page-Layout`.
- `GET /cameras/capabilities` reports `continuous_preview`, `zoom_steps` and `focus_lock`. The device list reports `usb_port`, `role_guess`, `zoom_steps`, `zoom_step`, `focus_locked`, `clock_offset_s`, `orientation` and `orientation_saved`.
- `image_formats` lists the formats a backend offers. The format RAW is still accepted and is read as RAW+JPEG. `GET` camera settings reports `stored_image_format`.
- `GET /cameras/preview/{i}` answers 503 with the code `preview_frame_failed` when a camera is connected but sent no frame. It answered 404 as for a camera that is not connected.
- Autofocus calibration and white-balance calibration on a backend that cannot calibrate answer 501. They answered 200 with `success: false` and the error text.
- `DELETE /projects/{id}` refusals answer `{code, message}`, with the codes `project_not_empty` (with the two counts), `project_files_held`, `project_manifest_foreign`, `project_manifest_keep_failed` and `project_files_remove_failed`.

---
- New routes: `PUT /auth/users/{id}/password`, `GET /system/storage/freeable`.
- `GET /system/storage` adds `reserve_bytes` and `usable_free_bytes`.
- A capture or an upload refused for the reserve answers 507 with `{code: "storage_reserve", free_gb, reserve_gb}`.
- A new password that is too short answers 422 with `{code: "password_too_short", min_length}`.
- A 422 for a request that failed validation carries `type`, `loc` and `msg` for each error, and no longer `input` or `ctx`.
- The free plan, the free job's result, a volume's offsite state, the 410 for a freed file and the export refusal carry `restorable`.
- The free routes (`GET` and `POST /collections/{id}/offsite/free`, `GET .../offsite/jobs/{job_id}`) admit operators.
- The Fisqua manifest is version 1.12. It carries `calibrationStatus` (`present` or `skipped`) and `calibration`, the list of color card shots with their camera, settings and digests. A unit with color card shots off sends `calibrationStatus: "skipped"`.
- Capture requests accept `client_capture_id`, a UUID. A repeated id is answered from the stored capture with `replayed: true`. `GET /cameras/capture-requests/{id}` answers the stored capture, `{"in_progress": true}`, 404 `not_found` or 410 `capture_no_longer_stored`. New refusals on capture: 409 `capture_in_progress`, `client_capture_id_in_use`, `capture_abandoned`, `capture_no_longer_stored`.
- More new routes: `GET`, `PUT` and `DELETE /system/camera-kind`; `PUT /system/unit/capture-key`; `PUT /users/me/language`; `GET /collections/{id}/colour-card`, `POST …/colour-card/sets`, `POST …/sets/{set_id}/shots`, `POST …/sets/{set_id}/complete`, `POST …/colour-card/skip`, `GET …/shots/{shot_id}/preview`. `GET /auth/setup/status` also returns `local` and `default_language`. `GET /system/unit` also returns `defaultLanguage`, `captureKey` and `colourCardShots`.
- Retake and fill requests accept `expected_image_ids` and are refused with 409 `record_changed` when the record's images differ.
- `GET /cameras/devices` adds `default_orientation`, the rotation a camera has by default for the page it photographs.

## [0.2.0] - 2026-10-31

0.2.0 keeps the archive's digitisation lists on the unit, lists the records waiting to be retaken, and puts retakes ahead of new volumes. It can also rebuild a volume digitised before Captua from images already in the bucket.

### Digitisation lists (Cola)
- Lists imported from Fisqua are now kept on the unit. The Cola screen shows them one at a time, with each list's items in the list's order.
- Admins and operators import from Cola. If a list's project does not exist yet, only an admin can import it, and Captua creates the project.
- After an import, Cola reports how many volumes Captua created, and each item it set aside, with the reason.
- Each item shows:
  - its title and reference code;
  - what the list asks for: a full digitisation, a full rescan, a spot recapture, or the completion of a volume;
  - the list's instructions, in full;
  - the stage and progress of its volume.
- The list can be filtered by what each item asks for.
- **Siguiente** marks the first item that is not yet done and can be opened for capture. While retakes are pending, items whose volumes have retakes come first.
- A full digitisation counts as done once every record in its volume is approved. An admin or reviewer can mark any item done, and remove the mark. Captua records who marked it and when.
- Lists imported before 0.2.0 show their items once they are imported again.

### The instruction on the capture screen
- When you capture into a volume named in a list, the instruction from the newest list naming it appears at the top of the capture screen. An example is the openings to recapture.
- By default the screen shows two lines. If the text is longer, **Mostrar todo** opens the rest, and the preview, the capture button and the thumbnail strip stay clear of it.

### Retakes
- **Por recapturar** lists every record rejected in review, whether on the unit or in Fisqua, oldest rejection first.
  - Each row shows the volume, the reason with its explanation, the reviewer's note, and who rejected it and when.
  - The list can be filtered by volume.
  - The side menu shows how many records are rejected.
- For admins and operators, **Volver a capturar** starts a guided recapture through the volume's pending records, in order.
  - After each retake, Captua opens the next record.
  - **Saltar por ahora** moves a record to the end.
  - The retake window shows why the record was rejected.
- The overview shows how many openings are waiting, in how many volumes, and which volume has the most.
- A record is pending while it is rejected. It stays pending after it has been prepared for retake, until a new capture replaces its image.

### The recapture turn
- While any record on the unit is pending, an operator can't start an empty volume.
  - Finishing the retakes of one volume allows one new volume.
  - The first capture into that new volume hands the turn back to retakes. Turns don't accumulate.
  - Captures into volumes that already have records are never blocked, and neither are retakes.
- The capture screen explains the block and links to a volume to retake. An admin can capture anyway. Cola shows whose turn it is.
- No one can send a volume with pending records to review. The volume page shows how many retakes are left.

### Volumes digitised before Captua
- With shell access to the unit, an admin can rebuild a volume digitised with two cameras before Captua, using `python -m app.core.rebuild_volume <stem> <bundle> --apply`.
  - The command reads a prepared bundle: the plan of records, plus each source image's digests and thumbnail.
  - The masters must already be copied to the bucket under Captua names.
  - Each opening becomes a paired record, with each camera's rotation from the plan. An image without a partner becomes a single record.
  - The masters stay in the bucket. Only thumbnails and metadata are kept on the unit.
  - Without `--apply`, the command only reports what it would do.
  - A rerun keeps finished records only if they match the plan.
- A rebuilt volume is handed over like any other. Openings rejected in Fisqua come back to Por recapturar.

### Rotation sent to Fisqua (optional)
- With `CAPTUA_FISQUA_ROTATE_DEG=true`, Captua writes the capture manifest as version 1.5, and each image carries its rotation as `rotateDeg`.
- The default is false, which leaves the manifest at version 1.1, unchanged. Turn it on only for a Fisqua that reads contract 1.5.

### Other changes
- A project's volume list shows each volume's real stage. Before, it showed placeholder states.
- On a freed record, the note that the master is in the bucket no longer covers the thumbnail.

### Fixes
- An import refuses a list containing a number too large to read, as it already refused `NaN`, instead of writing the value into the volume.
- An item whose stem ends in a line break is set aside as an invalid stem before it reaches the database.
- A record's rejection history starts with the rejection Por recapturar shows, also when two rejections were made at the same moment.

### For integrators
- New routes:
  - `GET /imports/digitisation-lists`
  - `PUT /imports/digitisation-lists/{list_id}/items/{position}/done`
  - `GET /records/to-retake`, `/to-retake/count`, `/to-retake/summary`
- New 409 responses: `recapture_turn` on `POST /cameras/capture` and `/capture/dual`, and `recaptures_pending` on `POST /collections/{id}/promote`.
- New setting: `CAPTUA_FISQUA_ROTATE_DEG` (or `DTK_`), default false.
- New CLI: `app.core.rebuild_volume`.

## [0.1.0-beta] - 2026-10-25

0.1.0-beta is the first release built to be tested in day-to-day operation in an archive. It is tested on one configuration: a Captua unit (the Raspberry Pi scanner) with two Canon EOS Rebel T7 cameras connected over gphoto2, and a monitor, keyboard and mouse.

Captua can be used on its own or with [Fisqua](https://fisqua.org), AMPL's open-source cataloguing platform for archives. It can be used offline, or with copies kept in the cloud. Each of these is a complete way of working.
- **On its own:** volumes take the archive's own reference codes, and a volume's files leave the unit through the export.
- **Offline:** the unit needs no internet connection to capture, review or export.
- **With Fisqua:** the codes come from the archive's Fisqua catalogue, and Captua sends each finished volume to Fisqua.
- **With the cloud:** Captua keeps copies of the images and the catalogue in a bucket.

### Volumes and file names
- A volume is whatever the archive catalogues as a single item and captures as a whole: a bound volume, a folder, a bundle of loose documents. Each volume now carries a reference code: the archive's own, or, for an archive that uses Fisqua, the item's code in its Fisqua catalogue.
- That code is the stem of every file name in the volume. A stem has at most 27 characters: lowercase letters and digits, in groups joined by single hyphens, as in `co-ahr-con-t055`. Nothing can be captured into a volume until it has a stem. Once images have been captured into a volume, its stem can't be changed or given to another volume. A volume's reference code and its stem are always the same; Captua refuses one that differs from the other.
- New images are named `<stem>-img_<nnnn>_c<n>`: the stem, a number counted per volume, and the camera. Numbers are never reused, including those of retaken pages.
- On the unit's storage, each volume's files now sit in a folder of their own, named after its stem. Inside are:
  - `captures` for the masters, the original files from the camera;
  - `previews` for the JPEGs made from RAW masters;
  - `thumbnails` for the thumbnails;
  - `metadata` for the metadata.
- Renaming a project or moving a volume to another project no longer moves or renames any file. At the first start after the update, Captua moves existing files into this layout.
- Renumbering a volume changes the order of its pages and leaves the file names as they are.
- Captua leaves RAW masters exactly as the camera wrote them. Each image's rotation is recorded beside it and travels with the export.

### Capture and interface
- **Guided tour:** a first-run tour walks through the six steps from creating a project to exporting a volume. You can open it again from Ayuda.
- **Hover help:** the icon-only controls on the capture screen say what they do when the pointer rests on them.
- **Thumbnail strips:** they keep the two pages of a spread together.
- **Sliders:** the brightness, contrast and saturation sliders change how the image looks on screen. They leave the file as it is. Captua resets the rotation when you move to the next page.
- **Camera rotation:** each camera starts at the rotation saved for it, also when the unit takes a moment to detect the cameras after it starts.
- **Camera panel:** it says when the capture system is not available, instead of reporting a missing camera.
- **Renumbering:** it reports how many records were renumbered.
- **Storage warning:** the overview warns every user when the drive that holds the volumes is 85% full or more.
- **Dialogs:** dialogs fit on the unit's 800×480 screen, and you can scroll one that is too long for it. Escape or a click outside closes a dialog, except while closing it would lose work in progress.
- **User menu and shutdown:** every screen has a user menu, opened from your name in the sidebar or from the avatar on the capture and volume screens. From it, every signed-in user can shut down or restart the unit, not only administrators.
- **Removed controls:** two controls that did nothing are gone: the Filtros buttons on the project and volume lists, and Recuérdame on the sign-in screen.
- **Register:** the interface addresses you as tú throughout.

### Review
- A page can be rejected for one of nine reasons, each with a line explaining it: motion blur, glare/reflection, shadows, out of focus, exposure, debris on surface, framing, obstruction, and other. A rejection for "Other" needs a note. A note can be up to 2,000 characters.

### Copies in the cloud (optional)
- On a unit set up with a bucket in the cloud (Backblaze B2), Captua copies each master and its preview there. It then checks each copy against the bucket's own list of what it holds.
- For each volume, you can see how much of it is already in the bucket.
- Once a day, Captua copies its catalogue (the database of volumes, records and images) to the bucket, encrypted.
- Once the bucket holds a whole volume, an administrator can remove its masters and previews from the unit to free space. Thumbnails stay on the unit. Before removing a file, Captua checks it against the bucket again.
- An administrator can bring a freed volume back from the bucket.
- Copying to the bucket can be paused on the unit during maintenance, and resumed afterwards.

### Working with Fisqua (optional)
- When a volume is sent for review, and every one of its files is in the bucket, Captua sends Fisqua the volume's capture manifest: the list of its files and their checksums, which is needed to register the volume in Fisqua. No one has to exchange files by hand.
- If the unit is offline at that moment, Captua sends the manifest once the connection returns.
- The volume page shows where the volume stands in Fisqua: sent, registered, being processed, waiting for review, or refused, with the reasons.
- When pages are reviewed in Fisqua, Captua applies the decisions on the unit: it approves or rejects each record with Fisqua's reason and note, and records any rotation correction. It skips any record whose images have changed since the volume was sent.
- If Fisqua can't read the manifests this version of Captua writes, Captua stops sending and tells the administrator. Captua tries again every six hours, and sends the refused volumes again once Fisqua reads its manifests, after an update to either.
- A unit without Fisqua can still download the capture manifest from the volume page.
- Captua can import a digitisation list exported from Fisqua (the items an archive plans to capture) and create a volume for each item.

### Welcome and credits
- The welcome screen offers "Get started in English" and "Empezar en español". Each sets the interface language.
- The welcome screen acknowledges the institutions and people who have made Captua possible. A QR code on the Credits page leads to the project's page on the AMPL website.

### Name on the network
- The interface is now at `http://captua.local`. An update renames a unit still called `digitool` to `captua`, and the unit still answers at `digitool.local`, so existing bookmarks still work.
- The unit's own screen reaches Captua without going through the network, so it keeps working when the Wi-Fi drops.
- After this update the unit's screen asks for the language once, because the kiosk now opens a different address.

### Updates
- A failed update puts the previous version back when that loses nothing. Otherwise it leaves the unit stopped, with a record of what happened and how to resolve it, so the unit never starts on code and a database that don't match.
- An update refuses to install a checkout with local changes, or a version older than the one installed.
- A rollback refuses to go ahead when restoring the backup would cut volumes off from their files, and lists them.
- The unit's logs no longer record the session tokens that image and download addresses carry.

### For units already in use
- Units on which images were captured before this release need a few one-time steps after updating. These are command-line tools run by whoever manages the unit:
  - recording copies already in the bucket, including those Fisqua made under the new file names;
  - raising a volume's capture number past the numbers those copies use;
  - marking files already removed from the unit as freed;
  - recording checksums for older previews.
- The order matters, and it is set out in the deployment guide.
- The unit's settings can now use `CAPTUA_` names, and Configuración shows them. Captua still reads the old `DTK_` names. If a setting is given under both names, the `CAPTUA_` value applies.

### Known limits
- The digitisation list is imported by uploading the file. It has no screen yet, and doesn't yet arrive from Fisqua on its own.
- Space on the unit can be freed only once a volume is in a bucket. A way to free space that doesn't need a bucket is planned: a copy of the volume to three separate media, checked before anything is removed.

### For maintainers

- **The unit is called `captua`** — New cards are named `captua` and answer at `http://captua.local` (`DTK_HOSTNAME` names a second unit at a site). `update.sh` renames a unit called `digitool` to `captua` and keeps `digitool.local` answering through 0.1.x, with an mDNS alias (`dtk-mdns-alias.service`); a unit named otherwise by hand is left alone. The alias needs `avahi-utils`, which the update installs from apt, under `--no-pull` too; a unit that cannot reach apt, or an update run with the new `--no-pull --offline`, keeps the name until an update that can. A rename cut off by a power cut is finished or undone at the next start of `dtk`. `scripts/provision-hostname.sh` does the work for both scripts.
- **The API is called on the page's own origin** — The frontend calls `/api` relative to the page (`PUBLIC_API_BASE=/api`), through nginx, so the unit works by its name, by its old name or by its IP address. The kiosk opens `http://localhost` instead of the frontend container on `:3000`, and asks for a login once after the update. `update.sh`, `update.sh --resolve-forward` and `rollback-update.sh` relaunch it, and the rename points the kiosk's Chromium profile lock, which names the hostname it was taken under, at the new name; `start-kiosk.sh` also removes a stale lock before it starts Chromium.
- **`name: dtk` in `docker-compose.yml`** — The Compose project name is written out instead of derived from the checkout's directory. On a unit it is unchanged; a development checkout in another directory gets new container and volume names once.

## [0.0.0-pre.3] - 2026-07-24

The first release under the software's name, **Captua**, and the first validated end-to-end on real hardware: a fresh Raspberry Pi 5 was provisioned from the written documentation and taken through both camera backends, power-cut recovery, and the full update and rollback cycle on the bench (July 23–24). Everything integrated since 0.0.0-pre.2 is included. Captua remains pre-alpha.

### Added

**A name and a visual identity**
The software is now **Captua**. The release completes the renaming throughout the interface and ships the new identity: the Captua logo and wordmark, light and dark favicons, and Mulish as the interface typeface.

**Per-unit secrets at first boot**
Captua ships as a cloned SD card, and anything on the card at imaging time is copied bit-for-bit onto every unit — including credentials. A new first-boot service detects placeholder or cloned secrets before the application starts, generates a per-unit signing key and database password, rotates the live Postgres password crash-safely, and records the Pi's hardware serial so a card moved to a new machine regenerates on its own. Imaging a test-booted master is now safe.

**Safe updates, with a way back**
The update script now dumps the database before migrating, does all its network work before stopping the service, refuses to run unattended when it cannot confirm the update is offline-safe, and verifies the stack came back up. A companion rollback script restores the pre-update dump and returns the code to the last recorded deployment — never blindly to the current tip.

**Storage on removable media**
External drives can be mounted, activated as the projects storage root, and safely unmounted from the interface. The privileged operations run through a scoped helper with a single sudoers entry, replacing the previous open-ended mount permissions; unmounting a drive that is the active storage automatically reverts to internal storage.

**A firewall, and kiosk escape hatches**
Provisioning now closes the appliance's LAN surface to the web interface, SSH, and mDNS only. The kiosk gets two documented recovery paths out of the box: Ctrl+Alt+F2 drops to a terminal (Ctrl+Alt+F1 returns), and a `dtk-no-kiosk` file on the boot partition skips the kiosk for a session.

**Interface in Spanish and English**
The interface now runs from a full bilingual catalog, selected at login; the choice persists across reboots.

**Integrity checking**
Administrators can reconcile the database, the files on disk, and the capture manifests from a single endpoint. The check is strictly read-only — it reports discrepancies and never deletes or moves anything. The backend also refuses to start on an unmigrated database, failing visibly instead of running against a wrong schema.

**Honest clocks**
The Pi has no battery-backed clock, so a power cut used to scramble capture timestamps. Setup now installs fake-hwclock and chrony: time persists across reboots and corrects itself whenever the unit is online.

### Fixed

**Provisioning survives a fresh start**
A verbatim run of the documented setup previously failed several ways: the setup script had lost its executable bit, nothing created the environment file (leaving the database half-initialized with wrong credentials), and the nginx image was never pulled — so a card shipped offline crash-looped on first boot. All fixed; setup also now installs the camera system packages explicitly and adds the operator to the docker group.

**Cameras work against the pinned environment**
The locked Python environment was ABI-incompatible with the system camera stack, so the ArduCam backend reported no cameras on a fresh install; the DSLR backend's bundled USB library detected nothing even when the command-line tools saw both bodies. The environment now pins numpy below 2 and builds python-gphoto2 from source against the system library. Camera import failures also now report the real error instead of a misleading claim about the operating system.

**Capture and display**
Collections over one hundred records display in full. The thumbnail strip keeps a stable order under rapid consecutive captures. The collection hierarchy endpoint no longer errors on nested collections. Uploads are size-capped with orphaned files cleaned up on failure. Renaming a project moves its file tree along with it. Storage-override writes are atomic, and a corrupt override file now fails loudly instead of silently falling back.

**Sessions and permissions**
Session handling got a guard against expired tokens, camera status checks are auth-aware, camera controls are admin-only, annotation deletion is properly guarded, and authentication failures return explicit 401s.

### Known limitations

Updating an existing unit requires a current pixi (the lockfile is now format v7) — check `pixi --version` on target hardware first. The in-backend guard against placeholder secrets is not yet implemented; the systemd ordering is the operative protection. ArduCam dual capture runs seven to eight seconds per pair at medium resolution (DSLR: about four) — optimization is tracked. The frontend is pinned at the bench-tested state; the volume workflow and bug-report panel land next cycle.

## [0.0.0-pre.2] - 2026-05-31

### Added

- **DSLR camera support via gPhoto2** — Canon EOS and compatible USB cameras now work alongside picamera2. Backend auto-selects via `CAMERA_BACKEND=gphoto2` env var.
- **RAW (CR2) capture** — Selecting RAW or RAW+JPEG format now correctly saves `.cr2` files. Previously the camera silently fell back to JPEG on every capture.
- **Orientation / rotation control** — Per-camera post-capture rotation (0°, 90°, 180°, 270° CW) for scanning manuscripts in portrait orientation. JPEG captures are pixel-rotated via Pillow; CR2 files receive an EXIF Orientation tag via piexif so RAW converters auto-rotate.
- **Live preview rotation** — The camera feed in the live-preview viewport reflects the selected rotation in real time so operators can frame shots correctly before capturing.
- **Floating rotation buttons on each camera feed** — Quick-access ↺ / ↻ buttons float over each camera feed (bottom-centre). Clicking them updates both the live preview rotation and the capture rotation without opening the sidebar. State stays in sync with the sidebar orientation control.
- **Nginx reverse proxy** — All traffic now routes through Nginx on port 80 (`/api/*` → backend, `/*` → frontend). Eliminates hard-coded port references in the browser.
- **Network discoverability** — Raspberry Pi is accessible on the local network by hostname (`digitool.local`) and by IP. `HOST_IP` and CORS origins are static values in `.env`, set by hand.
- **Documentation service** — Quarto-based docs rendered and served via Docker; includes device-setup guides for CM4 and Pi 5 + IMX519.
- **SD card distribution guide** — New developer documentation for distributing pre-imaged SD cards.
- **gPhoto2 device-setup guide** — Step-by-step instructions for connecting Canon DSLR cameras.

### Fixed

- **CR2 thumbnail in record viewer** — The modal image viewer (`img-viewer-frame`) now shows a renderable JPEG instead of sending the `.cr2` file directly to the browser (which browsers cannot display). The `_preview.jpg` sidecar is served when available.
- **`image_format` reverse mapping** — Camera configuration now correctly returns human-readable values (`JPEG`, `RAW`, `RAW+JPEG`) instead of internal PTP strings.
- **Capture path mismatch** — `GPhoto2Backend.capture_image()` previously returned the originally requested `.jpg` path even when the camera had saved a `.cr2` file. It now returns the actual saved path.
- **imageformat reset on every capture** — `apply_dslr_config()` was overwriting the camera's format setting to JPEG on every shot when no explicit format was configured. It now skips the PTP write when `image_format` is `None`, leaving the camera's own setting intact.
- **Record `format` field hardcoded to `"jpg"`** — The format stored in the database now reflects the actual file extension (e.g. `"cr2"`).

### Notes

- Project remains pre-alpha pending replication and validation on additional machines.
- Default capture orientation is 90° (portrait) to match typical book/manuscript scanning setups.
- piexif must be present in the pixi environment (`pixi run python -c "import piexif"`) for CR2 EXIF rotation to apply.

## [0.0.0-pre.1]

### Added

- Initial pre-alpha release baseline.

[0.0.0-pre.1]: https://github.com/UCSB-AMPLab/digitization-toolkit/releases/tag/pre-alpha
