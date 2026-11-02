# Digitization Toolkit - API Reference and Implementation Guide

Documentation of the backend API endpoints, data models, implementation details, and code examples for frontend integration.

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [Key Resources](#2-key-resources)
3. [API Reference](#3-api-reference)
4. [Testing the API](#4-testing-the-api)
   - [Option 1: Interactive Docs on Swagger UI](#41-option-1-interactive-docs-on-swagger-ui)
   - [Option 2: Complete Testing Workflow in Swagger UI](#42-option-2-complete-testing-workflow-in-swagger-ui)
   - [Option 3: Run Test Suite](#43-option-3-run-test-suite)
   - [Option 4: Manual Testing (cURL)](#option-4-manual-testing-curl)
5. [File Storage Architecture](#5-file-storage-architecture)
6. [Code Examples](#6-code-examples)
7. [Frontend Integration](#7-frontend-integration)
8. [Configuration](#8-configuration)

---

## 1. Quick Start

### Backend Setup

How to get the backend running:

The backend runs **in Docker for development** and **natively through pixi on the Raspberry Pi**. A legacy virtualenv + `pip install -r requirements.txt` still works on Linux, but pixi is preferred for new development (`.github/copilot-instructions.md`).

It does **not** work on Windows or macOS: `backend/requirements.txt` pins `picamera2` and `gphoto2`, which are Linux/Pi camera libraries, and `backend/pixi.toml` declares only `linux-aarch64` and `linux-64`. Use Docker on those platforms.

**Development — any machine, no cameras attached:**

```bash
./scripts/start-dev.sh
```

This brings the whole stack up in Docker — PostgreSQL, the FastAPI backend and the SvelteKit dev server — and applies Alembic migrations on startup. It is shorthand for:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml --profile with-backend up --build
```

**Production — on the Pi:** `./scripts/start.sh` runs the database and frontend in Docker and the backend natively via pixi, because camera access needs Pi-specific libraries (libcamera, picamera2) that cannot run in a container.

See `backend/DEVELOPMENT.md` for the dependency-manifest rules that follow from this split.

### Verify it works:

After `start-dev.sh` (development):

- **Frontend**: http://localhost:5173 (Vite dev server)
- **Interactive API Docs**: http://localhost:8000/docs (Swagger UI)
- **Health Check**: http://localhost:8000/health
- **ReDoc**: http://localhost:8000/redoc

After `start.sh` (production on the Pi), there is no Vite server: Nginx serves the UI and proxies the API on **port 80** — `http://<hostname>.local`. Port 8000 is not open to the LAN (see §3).

### Test everything:

Tests run inside the backend container:

```bash
# Run all tests
docker compose exec backend python -m pytest

# Or run specific test suites:
docker compose exec backend python -m pytest tests/unit/
docker compose exec backend python -m pytest tests/integration/
docker compose exec backend python tests/validate_system.py
```

---

## 2. Key Resources

| Resource | Location | Purpose |
|----------|----------|---------|
| **Endpoint reference** | `http://localhost:8000/docs` | Generated from the code; always current |
| **Backend Setup** | [../../backend/README.md](../../backend/README.md) | Quick start and environment setup |
| **Configuration Example** | [Code Examples](#complete-workflow-registration-to-gallery) | How to build configuration page |
| **Live Scan Example** | [Code Examples](#live-scan-page-example) | How to build live scan page |
| **Gallery Example** | [Code Examples](#galleryview-page-example) | How to build gallery page |
| **Device Setup** | `device_setup_CM4.qmd`, `device_setup_pi5_imx519.qmd` | Raspberry Pi configuration |

---

## 3. API Reference

The endpoint list, path and query parameters, and request/response schemas are **generated from the code** and served by the running backend:

| | |
|---|---|
| **Swagger UI** | [`http://localhost:8000/docs`](http://localhost:8000/docs) — interactive; send real requests, including authenticated ones |
| **ReDoc** | [`http://localhost:8000/redoc`](http://localhost:8000/redoc) — readable single-page reference |
| **OpenAPI schema** | [`http://localhost:8000/openapi.json`](http://localhost:8000/openapi.json) — machine-readable, for client generation |

FastAPI derives these from the routers themselves, so they cannot fall out of step with the implementation. This document deliberately does not duplicate them.

Two limits: the schema is only as complete as the routes declare it. Endpoints without a `response_model` — `POST /auth/login` and `GET /auth/setup/status` among them — appear with no response schema. On errors, the schema is partial: no route in `backend/app/api/` declares `responses=`, so the only error FastAPI advertises is the `422` with an `HTTPValidationError` body it adds automatically wherever a route validates input. **Every other code the application raises is absent from the schema: 400, 401, 403, 404, 409, 413, 429, 500, 501, 502, 503 and 504** — and so is the application's own `422`, which is a different thing from the automatic one. Two more can reach a client from the framework beneath the application, and the grep below does not see them: `405` from Starlette's router when the path exists and the method does not, and `416` from `FileResponse` when a `Range` header cannot be satisfied — the image download routes in `records.py` return one.

Three of those need more detail, because a client that assumes a shorter list mishandles them.

- **`422` has two meanings.** FastAPI's is a validation failure whose body is an object with a `detail` array. Thirty-one places in `backend/app/api/` raise their own, carrying a `detail` string or, on the handover and export refusals in `collections.py`, a dict — `{message, blocking_record_ids}`. Two of the thirty-one are the unit mode's `stem_required`, with `{code, message}` (`collections.py:555-557`, `:572-575`); a thirty-second, `unknown_reference_code`, carries `{code, message, referenceCode}` and is raised with a status taken from a variable, so the grep below does not count it (`_check_codes_with_fisqua`, `collections.py:89-96`). Both are described under The unit's mode, below. The move refusals that name records the same way are `409`s, not `422`s: records handed over for review, and records with files in the offsite bucket (`collections.py:771-780`, `:788-797`). And a refusal from the background export job never arrives as an error status at all: the job records it, and `GET .../export/status/{job_id}` returns it at `200` with the message in a top-level `error` field (`collections.py`). A client that reads every 422 as a malformed request misreports a volume refused for unapproved records.
- **`401` comes from one file, and `403` mostly does.** All fourteen 401s are in `app/api/auth.py`. Three are in `get_current_user`, the dependency of every route except `/health` and five auth routes, so a client can meet them anywhere. The other eleven are raised by the auth routes themselves — login, register, refresh and reset-password — for that route's own reason: a wrong password, a wrong bootstrap token at first-user registration (`_authorize_bootstrap`, called only there, `auth.py:67`), and at refresh and reset an invalid or expired token as well (`auth.py:183`, `:203`). The status code does not say whether the session has ended; the route and its message do. Three of the eight 403s are in `auth.py` too, one of them `RoleChecker.__call__` (`auth.py:243-246`), the role gate routes declare as a dependency. Two are domain rules: an annotation with a recorded creator may only be deleted by that creator or an admin, and one with none by anyone who can reach the route (`records.py:1224-1232`); and `_apply_status_change` checks the caller's role (`records.py:1399-1403`). `_apply_status_change` is also called from `promote_collection`, so a role refusal can arrive from the handover — but the bulk status route calls it too and catches the refusal and returns `200` with the records it accepted — including a record already in the requested status, which is a no-op (`records.py:1390-1391`, `:1501-1505`); a refused record is logged on the server and not reported to the client. The sixth 403 is the list import's: while projects are shown, an operator's list whose project does not exist yet is refused (`imports.py:133-134`; `list_import.py:836-840`). The seventh and eighth are the unit mode's `volumes_from_fisqua`, with `{code, message}`: in fisqua mode an operator may not create a volume, change its stem or reference code, or import a list (`_volumes_from_fisqua`, `collections.py:81-86`; `imports.py:117-120`; The unit's mode, below).
- **`500` is a documented outcome, not only a crash.** Fifteen routes raise it deliberately: a camera control that failed, a storage command (`lsblk`, mount, unmount) that failed, a file operation that failed, or a database commit that failed after files had already changed. `POST /collections/{id}/images/renumber` writes no file, so its 500, `"The database update failed, so no record was renumbered. Please retry"`, leaves every sequence as it was (`collections.py:1054-1062`). When the commit of `POST /records/{id}/images` fails, the route unlinks the saved file and thumbnail before raising, and the line already appended to the volume's capture manifest stays (`records.py:765-794`). A failure after the commit, in the refresh at `records.py:795`, is also a 500 and cleans nothing up, so the two cannot be told apart from the status alone.

To re-derive this rather than trust it, which is what let the previous list go stale:

```bash
grep -rhoE 'HTTPException\(\s*(status_code\s*=\s*)?(status\.HTTP_)?[0-9]{3}|status_code\s*=\s*(status\.HTTP_)?[0-9]{3}' backend/app/ \
  | grep -oE '[0-9]{3}' | sort -u
```

Then drop the success codes the decorators declare — 200, 201, 202, 204. One raiser sits outside `backend/app/api/`: `app/core/db_errors.py`, which turns any `IntegrityError` — not only a unique-constraint one — into a 409 carrying a message and, when one could be recovered, the constraint name. For any single route, read it: the `HTTPException` calls are explicit, and nineteen callables in `backend/app/api/` raise on a route's behalf — `_authorize_bootstrap`, `get_current_user` and `RoleChecker.__call__` in `auth.py`; `_zone` in `activity.py`; `_check_codes_with_fisqua` in `collections.py`, which raises the lookup's `422` or `409` with the status the refusal carries; `_refuse_capture_without_volume_or_stem`, `_refuse_retake_out_of_the_operators_hands`, `_refuse_a_new_volume_out_of_turn`, `_refuse_resolution_in_filename`, `_resolve_capture_target` and `_take_filename_index` in `cameras.py`; `_read_capped` in `imports.py`; `_refuse_a_name_that_is_a_stem` and `_update_project_held` in `projects.py`; `_stored_master`, `_image_row`, `assert_movable`, `_assert_promotable` and `_apply_status_change` in `records.py` — so a route can return a code its own body never names.

A hand-written endpoint table, data-model list and error-code table used to be kept here. By the time they were checked they covered barely half the API, documented three roles incorrectly, and presented one error shape as universal, when capture endpoints report failure as `{success: false, error: ...}` at HTTP 200. They were removed rather than repaired.

What remains here is what a schema cannot express: how to get the stack running, how to test it, how storage is laid out, worked examples, and the reasoning behind the architecture.

**A volume's identity — on `/collections` requests and responses.** A volume (a row in `collections`) carries the identity defined by exchange contract 1.1: a file name stem and the catalogue item's reference code. Records have no catalogue identifier: `records.external_id` was removed in migration `a7c1e9d2b4f6`. The schema gives the pattern and the lengths; the rules below are the ones it cannot state.

- **`filename_stem`.** The slug that, under exchange contract 1.1, the volume's image file names are built from (`<stem>-img_<nnnn>_c<n>`), and which the contract requires to equal the volume's reference code. New captures and uploads are named from it (see Filename Format below). A lowercase slug (`^[a-z0-9]+(-[a-z0-9]+)*$`) of at most 27 characters, so that `<stem>-img_0000` fits the 36-character pair id; a stem that does not match, or is longer, is refused with FastAPI's validation `422`. Required on `POST /collections/`: `CollectionCreate` declares it without a default (`app/schemas/collection.py:71-74`), so a request without one is refused with FastAPI's validation `422`. Optional on `PATCH /collections/{id}`, and the column is nullable, so that a volume created before stems existed can be given one. Unique on the unit; a duplicate is refused with `409`, naming the constraint `collections_filename_stem_key`. Before the volume has captured, a `PATCH` can set, change or clear the stem; a volume whose stem is cleared cannot be captured into until it is given another. A `NULL` stem can be set at any time, including on a volume that already has images. Once a volume has a stem and has captured (`capture_counter` above 0, or any image on its own records, superseded ones included), a request to change or clear the stem is refused with `409`.
- **The stem names a directory.** A volume with a stem keeps its files in `<projects root>/<stem>/`, beside the project directories (section 5). So a stem is refused with `409` when it equals a project's directory name, or when `<projects root>/<stem>/` exists, holds a file, and the volume has no image there (`stem_directory_conflict`, `app/models/collection.py:173-205`). `POST /collections/` and `PATCH /collections/{id}` check this first and answer with `{message}` in `detail` (`app/api/collections.py:186-189`, `:609-612`). `POST /projects/` and `PUT /projects/{id}` refuse a project name whose directory would be a volume's stem with `409` and a plain-string `detail` (`_refuse_a_name_that_is_a_stem`, `app/api/projects.py:171-175`). A `before_flush` listener refuses the same collisions from any other writer (`app/models/collection.py:601`), and `app/main.py:131-134` answers it with `409` and `{message}` in `detail`. No file is moved when a stem is set. New captures and uploads into the volume are written to `<stem>/captures/` at once; the backend moves the volume's existing files at its next start (section 5).
- **A capture needs a volume with a stem.** `POST /cameras/capture` and `POST /cameras/capture/dual`, retakes included, refuse a request before any camera is touched (`trigger_capture`, `app/api/cameras.py:833-870`; `trigger_dual_capture`, `:1064-1122`; with `_refuse_capture_without_volume_or_stem`, `:57-81`, and `_refuse_retake_out_of_the_operators_hands`, `:84-94`). After FastAPI's own validation of the body, the checks run in this order, and the first that fails gives the answer: `include_resolution_in_filename` set to `true`, `422` with `"A capture's file name cannot carry its resolution: the exchange contract fixes the name."` (`_refuse_resolution_in_filename`, `:193-196`); a `record_id` that matches no record, `404` with `"Record N not found"`; no `collection_id`, or `0`, `409` with `"Captures must go into a volume."`; a `collection_id` that matches no volume, `404`; for a retake (a request with a `record_id`), a record that belongs to no volume, the same `409`, and a record in a volume other than the one named, `409` with `"A retake must go into the record's own volume."`; then a volume without a stem, `409` with `"This volume has no file name stem. Give it one before capturing into it."`; then a retake of a record in review or approved, `409` with `"Only a captured or rejected record can be retaken."`; then, on `POST /cameras/capture` only, a retake of a placeholder (`missing_side` `both`), `409` with `detail` `{code: "placeholder_needs_dual", message: "This record is a placeholder for a whole opening; capture it with both cameras."}` (`PLACEHOLDER_NEEDS_DUAL_DETAIL`, `cameras.py:37-40`; `:861-863`); then a retake in the other capture mode, `422`. `POST /cameras/capture/dual` with `afterRecordId` adds its own checks (Openings and pages never captured, below). A retake that names another volume without a stem therefore gets the retake message. After the camera connection check, and before the shot, the capture's file name is taken (`_take_filename_index`, `:173-190`). It is refused with `409` and `"This volume has reached the limit of 9999 captures. A new volume is needed. Nothing was captured."` when the volume's next capture number would be above 9999, including while numbers already taken are passed over, and with `"The next capture numbers of this volume are already taken by files on disk. Nothing was captured."` when more than 100 numbers in a row are taken (`app/core/capture_naming.py:34-50`, `:205-247`). A refused name is rolled back and uses no number. A retake supersedes the record's current images; a rejected record returns to `captured`, and a captured one stays `captured` (`cameras.py:1036-1040`, `:1307-1309`). `POST /records/{id}/images` refuses an upload on the same terms: a record attached straight to a project with the first message and a volume without a stem with the second, before anything is written (`app/api/records.py:672-675`), and a name that cannot be taken with the same two `409`s as a capture, the 9999 limit included, before it writes any file (`:705-709`). By then `ensure_volume_dirs` has created the volume's directories (`:697`). The details are plain strings, defined in `app/core/volume_stem.py:24-27` and `app/core/capture_naming.py:45-50`. The stem is read under `SELECT … FOR UPDATE` on the volume row (`locked_volume_query`), and `PATCH /collections/{id}` takes the same row lock through `_locked_collection_query` (`app/api/collections.py:69-71`, `:565`), so on PostgreSQL a `PATCH` that sets or clears the stem waits until the capture's transaction commits. On SQLite neither query adds a lock clause. `POST /cameras/test-capture/{camera_index}` stores nothing and is not refused.
- **`external_id`.** The item's `referenceCode` under the exchange contract. Stripped of surrounding whitespace in requests; a blank value is refused with FastAPI's validation `422` (a `detail` array). Unique; a duplicate is refused with `409`, naming `ix_collections_external_id`. Written once: a request to change or clear a stored value is refused with `409`.
- **A volume's reference code is its stem.** When a volume has both `external_id` and `filename_stem`, the two are the same value. A write that would leave a volume with both set and different is refused with `409` and `detail` `{message, reason, external_id, filename_stem}`. `reason` is `reference_code_differs_from_stem`, and `message` reads `The reference code '<external_id>' is not the file name stem '<filename_stem>'; a volume's reference code is its file name stem.` (`ReferenceCodeDiffersFromStemError`, `app/models/collection.py:66-84`; its handler, `app/main.py:143-149`). The rule is a `before_flush` listener, so it applies to `POST /collections/`, to `PATCH /collections/{id}` and to every other writer through the ORM (`_refuse_a_reference_code_that_is_not_the_stem`, `app/models/collection.py:554-577`). It judges the pair as the flush writes it, so a request that sets both at once is accepted when they are equal, whatever the order of the fields. It checks a new volume, or a volume whose stem or reference code changed in the flush; a stored volume whose two values already differ is not refused for an unrelated edit. A volume with no `external_id`, or with no stem, is not checked: a volume with no `external_id` has its stem as its reference code, in the capture manifest and in the Fisqua link (below). A blank `external_id` is refused earlier, with the validation `422` above. `query().update()` and raw SQL go around the listener. The digitisation-list import refuses an item whose `filenameStem` differs from its `referenceCode` before the database, with the reason `filename_stem_differs_from_reference_code`, and a pair that reaches the flush is reported under the same reason (`list_import.py:459-460`, `:697-701`).
- **`capture_counter`.** Read-only. It is raised for each capture event (a dual capture is one event) and for each upload into a volume, by `take_filename_index` (`app/core/capture_naming.py:205-247`), which calls `next_capture_number` in `app/core/capture_counter.py`, a single atomic `UPDATE … RETURNING`, once more for each number it passes over. It is never lowered. An operator can raise it to a given number with `raise-capture-counter` (section 5, Offsite copies).
- **`stem_reserved`.** Read-only: the volume has a stem and has captured. A `DELETE /collections/{id}` on such a volume is refused with `409`, even when the volume is empty, so its stem cannot be issued again. A volume counts as having captured when its `capture_counter` is above 0, when it has any image, or when any `offsite_objects` key is of the form `<tenant>/<stem>/<rest>` for its stem, under any tenant and whether or not the key's image still exists (`has_captured`, `app/models/collection.py:363-379`; `offsite_keys_under_stem`, `:87-115`).
- **A stem with offsite objects under it is held.** A new volume, or a change of stem, is refused with `409` and `{message}` in `detail` when any `offsite_objects` key is of the form `<tenant>/<stem>/<rest>` for that stem, under any tenant, unless the key's image belongs to a record of the same volume. The message is `"Images are stored offsite under the file name stem <stem>, so it cannot be given to this volume."` The check is a `before_flush` listener, so it applies to every write made through an ORM session, and raw SQL goes around it; `app/main.py` answers it (`_refuse_a_stem_held_offsite`, `app/models/collection.py:580-597`; `app/main.py:137-140`). The list import rejects such an item as `filename_stem_held_offsite` (`app/core/list_import.py:147-149`, `:692-696`).
- `date`, `date_start`, `date_end`, `sequence` and `custom_attributes` describe the volume. An end date before its start is refused with `422` when both are in the request, and with `409` when the end is checked against a stored start.

Refused identity changes and the delete refusal return `409` with `{message}`; constraint violations return `{message, constraint}`. Both rules are in `app/models/collection.py`. The write rules are attribute validators, so they apply to every ORM assignment. The delete refusal is a `before_flush` listener, so it also applies to `session.delete()`, to the delete cascades from `Project.collections` and `Collection.child_collections`, and to delete-orphan. A bulk `query().update()`, raw SQL or a database-level `ON DELETE CASCADE` goes around both.

**A volume's record order — `records.sequence`.** The records of a volume are ordered by their `sequence`. Under exchange contract 1.1, section 3, renumbering rewrites records' `sequence` and never renames a file: a file's name carries its capture number, and order is the records' `sequence` (`app/core/record_sequence.py:1-8`). Every path that puts a record into a volume or rewrites the order in one keeps the volume's sequences distinct.

- **A record added to a volume takes the next sequence.** A record created by `POST /cameras/capture` or `POST /cameras/capture/dual` (not a retake), a record created by `POST /records/` with a `collection_id`, and a record moved to another volume by `PATCH /records/{id}` take the sequence after the highest in that volume; in a volume with no sequenced record the first is `1` (`next_sequences`, `record_sequence.py:152-170`; `app/api/cameras.py:43-54`, `:977`, `:1213`; `app/api/records.py:209-213`, `:548-552`). `POST /records/` does not use a `sequence` in the body, and gives no sequence to a record outside a volume or to one naming a volume that does not exist. `PATCH /records/{id}` takes no `sequence` in its body; a `sequence` sent there is ignored (`RecordUpdate`, `app/schemas/record.py:268-275`). A retake keeps its record's sequence. `POST /collections/{id}/move-records` gives the moved records the sequences after the target's highest, in their listing order in the source (`collections.py:804-813`). In each case the volume's row is locked before the highest sequence is read and stays locked until the commit.
- **A record inserted after another is given the sequence right after it.** Under contract 1.9, section 10.2, two paths put new records right after a given record of the volume instead of after the highest: `POST /cameras/capture/dual` with `afterRecordId` (one record) and the placeholders of `POST /collections/{id}/records/missing-opening` or of a Fisqua request (`count` records). Each adds the count to the sequence of every record of the volume whose sequence is after the given record's, and gives the new records the freed values (`insert_after`, `record_sequence.py:173-204`). The given record may have any status, `excluded` included. A record without a sequence keeps none. When the given record has no sequence, or shares it with another record, the volume is first numbered 1..N in listing order, as a renumber does. No file is renamed, read or written. The volume's records and then its row are locked as for a renumber. On the two routes, the same `409` with `"The volume changed while it was being renumbered. Try again."` is returned after five attempts; on a Fisqua request, the decisions set is rolled back and `apply_decisions` returns the status `error` (`fisqua_decisions.py:625-628`).
- **`POST /collections/{id}/images/renumber`.** Admins and operators may renumber. The route sets the `sequence` of every record of the volume to 1..N in listing order: by `sequence`, records without one last, records that share one by id (`listing_order`, `record_sequence.py:58-60`; `renumber_volume_records`, `:118-131`). No file is renamed, moved or written, no manifest line is written, and records of other volumes are not touched. The response is `200` with `{renumbered: N}`, N being the number of records in the volume (`collections.py:1027-1067`). A volume that does not exist is refused with `404`. A failed commit is the `500` described above. The renumber is recorded in the activity log as `images_renumbered`.
- **`PATCH /collections/{id}/records/reorder`.** Admins and operators may reorder. The body is `{ordered_ids: [...]}`, and the list must name every record of the volume exactly once. Each record's `sequence` is set to its position in the list, counted from 1. An empty list is refused with FastAPI's validation `422` (`app/schemas/record.py:461-469`). A list that leaves a record out, repeats one or names a record of another volume is refused with the application's `422` and the plain-string detail `"ordered_ids must name every record of the volume exactly once."`, and nothing is written (`reorder_volume_records`, `record_sequence.py:134-149`; `collections.py:917-947`). The response is `200` with `{reordered: N}`. A volume that does not exist is refused with `404`.
- **Both answer `409` when the volume keeps changing.** Renumber and reorder lock the volume's records and then the volume's row. If a record was added to the volume between the two, the transaction is rolled back and the locking starts again. After five attempts that each found the volume's records changed, the request is refused with `409` and the plain-string detail `"The volume changed while it was being renumbered. Try again."` (`lock_volume_records`, `record_sequence.py:86-109`; `LOCK_ATTEMPTS` and the message, `:46-47`; `collections.py:940-942`, `:1048-1050`). Nothing is written. On SQLite no lock clause is emitted (`record_sequence.py:19-20`).
- **A renumber or reorder during an export fails the export.** Neither route is refused while an export of the volume is queued or running. When the export job has planned its payload, and before it writes anything, it compares each record's status, `sequence` and current images with what they were when the job passed its gate. If any differ, the job fails: `GET /collections/{id}/export/status/{job_id}` returns `state: "failed"`, the `error` `"Cannot export: the collection changed while the archive was being assembled (N record(s) affected). Try again."` and `detail: {blocking_record_ids}` (`app/core/export_service.py:161-163`, `:234-256`; `app/core/export_jobs.py:36-46`, `:177-180`).

**Renaming, moving and deleting a volume — `PATCH /collections/{id}`, `POST /projects/{id}/move-collections` and `DELETE /collections/{id}`.** A volume belongs to a project or to a parent volume, never to both and never to neither (`check_collection_parent`, `app/models/collection.py:456-459`).

- **A null parent makes the volume top-level in its root's project.** `PATCH /collections/{id}` with `parent_collection_id: null` on a nested volume follows the volume's chain of parents to the top-level volume it hangs from and gives the volume that volume's `project_id`, so the volume becomes a top-level volume of the project its former root belongs to. The chain is read under the volume's row lock, before anything is changed. On a volume that is already top-level, the null is dropped and nothing changes (`app/api/collections.py:624-632`). `CollectionUpdate` has no `project_id` field, so a `PATCH` cannot name the project (`app/schemas/collection.py:92-98`).
- **Each change is recorded in the activity log after its commit.** A refused or failed request records nothing (`collections.py:696`). Each value in a detail is written as Python writes it: a string quoted, an absent value `None`.
  - `collection_renamed`, at `INFO`, when a `PATCH` changes the volume's name or its stem, a stem set for the first time included. The subject is the new name, and the detail is `id=<id>; stem <old> -> <new>; name <old> -> <new>`, with both pairs whichever changed (`collections.py:698-704`; `_volume_change_detail`, `:74-78`).
  - `collection_moved`, at `INFO`, when a `PATCH` changes the volume's project or its parent, with the detail `id=<id>; project <old> -> <new>; parent <old> -> <new>` (`collections.py:705-711`). `POST /projects/{id}/move-collections` records one `collection_moved` for each top-level volume of the source project, read before the move, with `parent None -> None`, and then its own `collections_moved` entry. The sub-volumes, which follow their parents, get no entry of their own (`app/api/projects.py:327-328`, `:358-365`).
  - `collection_deleted`, at `WARN`, when `DELETE /collections/{id}` has committed. The subject is the volume's name, and the detail is `id=<id>; stem <stem>; project <id>; parent <id>; records=<n>; images=<n>; sub-collections=<n>`. The route refuses a volume that still has records or sub-volumes, so the three counts are always `0` (`collections.py:891-908`).

**A volume's offsite copy — `GET /collections/{id}/offsite`, `GET /system/catalogue-backup` and the refusals.** The backend uploads every image of each volume with a stem to the offsite bucket, records each object in `offsite_objects`, and uploads an encrypted dump of the catalogue to the same tenant prefix (section 5, Offsite copies). This is what reaches a client.

- **`GET /collections/{id}/offsite`, the received indicator.** Admins, operators and reviewers may read it (`allow_read_only`, `app/api/collections.py:60`). A volume that does not exist is refused with `404` (`app/api/collections.py:326-327`). The response carries `collection_id`, `filename_stem`, `uploadable` (the volume has a stem), the counts `total`, `verified`, `pending` and `refused`, `last_verified_at` (the latest verification among the volume's objects, or `null`), `received`, `refusals`, `freed_files` and `freed_bytes` (below, Freeing a volume), `held` and `hold_file` (the upload hold, below), and `fisqua` (`null` when Fisqua is not configured; otherwise the object described under Delivery to Fisqua, below) (`get_collection_offsite_state`, `app/api/collections.py:301-328`; `volume_upload_state`, `app/core/image_upload.py:1511-1519`; `_object_counts`, `:1440-1508`). `total` counts one capture object for each image of the volume's records, superseded images included, and one preview object for each RAW master whose preview has a row or is on disk (`:1481-1490`). `pending` is `total` less `verified` and `refused`, so it includes objects not yet tried. `received` is `true` only when `total` is above `0` and every object is verified; a volume with nothing to upload has received nothing (`:1504-1507`). Each entry of `refusals` carries `image_id`, `kind` (`capture` or `preview`), `reason`, `key`, `local_sha1`, `remote_sha1` and `refused_at` (`:1500-1503`). A volume without a stem is answered with `uploadable: false`, zero counts, `received: false` and no refusals, and still carries `held` and `hold_file` (`:1515-1518`).
- **The `refusal` values.** There are two, and a check constraint admits no other (`REFUSALS`, `app/models/offsite_object.py:46`, `:71-74`). `remote_differs`: before the upload, the listing showed an object at the key with another SHA1, which is stored as `remote_sha1`. `fixity`: the file's sha256 is not the one its capture record holds; `remote_sha1` is then `null`. An image with no capture-time sha256 is not refused on that ground (`offsite_object.py:16-20`; `image_upload.py:746-756`, `:772-775`). Nothing is uploaded for a refused object, and the uploader does not retry it. Each refusal is also written to the system log as `image_upload_refused` at `ERR`, with the key as subject (`image_upload.py:681-690`).
- **`GET /system/catalogue-backup`.** Admins, operators and reviewers may read it (`app/api/system.py:118-153`). `enabled` is `true` when `DTK_OFFSITE_REMOTE` is set and `DTK_OFFSITE_TENANT` holds a valid tenant prefix (`is_configured`, `app/core/catalogue_backup.py:247-254`). `last_verified_at`, `object` and `detail` come from the most recent `catalogue_backup_verified` entry in the system log, and are `null` on a unit that has never verified a dump (`last_verified_backup`, `catalogue_backup.py:628-647`). `object` is the dump's name, `catalogue-<YYYYMMDD-HHMMSS>-<6 hex digits>.sql.gz.age`, and `detail` reads `verified at <remote>/<tenant>/<prefix>: <n> bytes encrypted, <n> raw, sha1 <sha1>` (`_object_name`, `:284-295`; `:755`, `:788-791`). `held` and `hold_file` report the upload hold (below); `held` is `true` while the file exists, and `hold_file` is its path whether or not it exists (`hold_state`, `app/core/offsite_hold.py:58-61`; `app/api/system.py:147`). `images` is the image upload's summary for the unit (`unit_upload_summary`, `image_upload.py:1522-1546`): `enabled`, `tenant`, `misconfigured`, `volumes` (the volumes with a stem), `volumes_received`, the counts `total`, `verified`, `pending`, `refused`, `freed_files` and `freed_bytes` summed over those volumes, `last_verified_at`, `held` and `hold_file` (the same two values as at the top level), and `last_run`, the result of the upload's most recent run in this backend process. `last_run` is `null` until the first run after a start (`:1578`, `:1626-1648`); a run's result has `status` (`done`, `stopped`, `held`, `aborted` or `failed`), the counts `uploaded`, `already_present` and `unverified`, the lists `refused`, `conflicts` and `skipped`, `error` and `finished_at` (`RunResult.as_dict`, `:510-521`; the statuses, `:809-815`). A run in offline mode returns `{status: "off_in_this_mode", mode}` and nothing else, and a run already draining when the unit is switched to offline stops before its next object with the full result and status `off_in_this_mode` (`image_upload.py:831-832`, `:851-854`; The unit's mode, below). `fisqua` is the unit's Fisqua summary, described under Delivery to Fisqua, below (`unit_fisqua_summary`, `app/core/fisqua_outbox.py:1779-1793`; `app/api/system.py:137`, `:152`).
- **The upload hold.** While the file named by `DTK_OFFSITE_HOLD_FILE` exists, nothing is sent offsite. The default is `offsite-hold` in `DTK_DATA_DIR`, `/var/lib/dtk/offsite-hold` on a unit, and only the file's existence counts (`hold_file`, `is_held`, `app/core/offsite_hold.py:48-55`; `offsite_hold_file`, `app/core/config.py:251-253`). The backend only reads the file; no script creates or removes it. An operator creates it by hand during an upgrade, before the tenant is written to `offsite.env`, and removes it after the one-time commands (`adopt`, `mark-freed` and the others) have run. It is read at the start of every run and not when a schedule starts, so a hold that is created or removed applies from the next tick, with no restart. The routes show it as `held` and `hold_file` on `GET /collections/{id}/offsite` and `GET /system/catalogue-backup` (above). While it exists:
  - the image upload lists and uploads nothing and returns status `held` with `hold_file`; a run held at its start returns `{status: "held", hold_file}` and nothing else, and that is what `last_run` holds (`image_upload.py:835-836`, stored as it is at `:1632`). A run already draining checks the file between objects and stops after the object in progress; its result is the full run result with status `held` and no `hold_file` (`:845-849`, `:884`). When a run did work, the uploader logs `image_upload_run` at `INFO` if its status is `held` and nothing was refused (`:875`);
  - the Fisqua send pass and the Fisqua status poll each return `{status: "held", hold_file}` at their start, make no call to Fisqua and promote nothing (`run_fisqua_outbox`, `app/core/fisqua_outbox.py:1281-1282`; `poll_fisqua_status`, `:1455-1456`);
  - the catalogue dump is not taken and the run returns status `held` with `hold_file`; the sweep of stale dumps still runs (`catalogue_backup.py:730-731`);
  - `POST /collections/{id}/offsite/free` is refused with `409` (below). The dry run, `GET /collections/{id}/offsite/free`, and `POST /collections/{id}/offsite/restore` are not refused. The free is held because the upgrade's one-time commands may still be completing the volume's offsite rows and freed state; the dry run changes nothing, and restore is the way back for a freed file (`offsite_free.py:690-702`; `app/core/offsite_hold.py:19-22`). A free already running when the file is created is not stopped.
- **The `misconfigured` state.** When `DTK_OFFSITE_TENANT` is set to a value that is not a tenant prefix, after surrounding whitespace and slashes are stripped (`image_upload.py:144`), `images.misconfigured` carries one of three messages, `images.tenant` is `null`, and both `enabled` fields are `false`; otherwise `misconfigured` is `null`. A tenant prefix is Fisqua's tenant slug: 1 to 63 lowercase letters, digits and single hyphens, starting with a letter, with no hyphen at the end and no double hyphen, and none of `platform`, `www`, `api`, `admin` and `app`. The checks run in this order, each with its message: not matching the pattern, `CAPTUA_OFFSITE_TENANT='<value>' is not a tenant prefix (lowercase letters, digits and single hyphens, starting with a letter)`; a reserved name, `CAPTUA_OFFSITE_TENANT='<value>' is reserved by Fisqua and cannot be a tenant prefix`; and more than 63 characters, `CAPTUA_OFFSITE_TENANT is <n> characters long; a tenant prefix is at most 63`. `scripts/provision-rclone.sh` checks a tenant by the same rule (`valid_tenant`, `scripts/provision-rclone.sh:638-646`). (`TENANT_PATTERN`, `image_upload.py:109-114`; `configured_tenant`, `:137-161`; `:1524-1534`). The backend starts neither schedule at boot in that state, so no image and no dump is uploaded and nothing is written to the system log, and `last_verified_at` keeps the date of the last dump verified before (`catalogue_backup.py:879-884`; `image_upload.py:1583-1585`). A missing or invalid `DTK_OFFSITE_DUMP_RECIPIENT` is not shown by the route: `enabled` stays `true`, each run records `catalogue_backup_failed` at `ERR` with the detail `not run: <reason>` and writes no dump, and `last_verified_at` stops advancing (`catalogue_backup.py:743-749`).
- **A record with a file in the bucket stays in its volume.** Any `offsite_objects` row for one of a record's images, verified, pending or refused, holds the record in its volume, because the object's key is under the volume's stem and never changes (`records_stored_offsite`, `image_upload.py:1416-1433`). The row is committed before the upload starts, so the record is held from the moment its first key is reserved (`:778-782`). Three routes change a record's volume, and each checks this under the record's row lock, after its handover refusal (`assert_movable`):
  - `PATCH /records/{id}` that changes the record's volume is refused with `409` and the plain-string detail `"This record's files are already stored offsite under this volume, so it cannot be moved to another volume."` when the record is in a volume, or when the request leaves it in none (`STORED_OFFSITE_MESSAGE`, `image_upload.py:1410-1413`; `app/api/records.py:530-536`). A `project_id` in the body clears `collection_id`, so it counts as a change of volume (`records.py:500-507`).
  - `POST /projects/{id}/add_record/{rec_id}`, which detaches the record from any volume, is refused with `409` and the same detail when the record is in a volume and any of its images has an offsite row, after the handover refusal (`assert_movable`). A record outside every volume is not checked, so only its project changes (`app/api/projects.py:124-135`).
  - `POST /collections/{id}/move-records` to another volume is refused whole with `409` when any record of the volume has such a row, before anything is moved. The `detail` is `{message, blocking_record_ids}`, with the message `"Cannot move: N record(s) have files already stored offsite under this volume: [ids]."` (`collections.py:786-797`).
- **The way back for a record outside every volume.** A record with offsite rows and no volume (one taken out before `add_record` checked for them) can be put back into a volume only by `PATCH /records/{id}`, and only into the volume whose stem all its keys are under, `<tenant>/<stem>/...`, with `<tenant>` the configured `DTK_OFFSITE_TENANT` (`offsite_keys_under_volume` and `_key_stem`, `image_upload.py:1345-1371`). The target volume's row is locked after the record's before the keys are compared (`records.py:537-542`). A `PATCH` that keeps such a record outside every volume and changes only its `project_id` is not checked (`records.py:530`), and neither is `POST /projects/{id}/add_record/{rec_id}` for it (`projects.py:132`). Any other target, a volume that does not exist included, is refused with `409` and a plain-string detail from `stranded_offsite_message` (`image_upload.py:1374-1399`):
  - all keys under one stem: `"This record's files are stored offsite under the volume stem <stem>, so it can be put only into the volume with that stem."`;
  - keys under more than one stem: `"This record's files are stored offsite under more than one volume stem (<stems>), so it can be put into no volume."`;
  - a key that is not of the form `<tenant>/<stem>/<rest>`, such as an adopted key or one under an earlier tenant: `"This record's files are stored offsite under keys that name no volume of this unit, so it can be put into no volume."`;
  - no valid `DTK_OFFSITE_TENANT`: `"This record's files are stored offsite, and no valid DTK_OFFSITE_TENANT is set, so their keys cannot be matched to any volume of this unit. It can be put into a volume only once DTK_OFFSITE_TENANT is set, and then only into the volume its keys are under."`
- **The files-being-read hold.** To read an image, the uploader holds the image's volume for a short span, in which it re-reads the image's row and makes a hard link to its file (`hold_for_reading`, `app/core/export_jobs.py:107-138`; `_read_object`, `image_upload.py:551-634`). A request that takes the hold for file changes on that volume during the span is refused with `409` and the plain-string detail `"Captua is preparing a file of this volume for the offsite copy. Try again in a moment."` (`FILES_BEING_READ_MESSAGE`, `export_jobs.py:55-57`, checked at `:97-98`). The routes that take that hold are `DELETE /records/{id}`, `DELETE /records/images/{img_id}` for a current image, `POST /collections/{id}/move-records` for the source volume, and the free, its dry run and the restore below (`records.py:612`, `:920`; `collections.py:817`; `app/core/offsite_free.py:418`), and, only for volumes with files still in the name-based layout, `PATCH /collections/{id}` with a rename or a re-parent, `PUT /projects/{id}` with a rename and `POST /projects/{id}/move-collections` (`collections.py:653`; `projects.py:212`, `:329`). `PATCH /records/{id}`, `POST /projects/{id}/add_record/{rec_id}` and the renumber do not take it; they rewrite rows and move no file (`image_upload.py:563-567`). In the other direction, the uploader skips an image whose volume a request holds for file changes, and tries it again on its next run (`image_upload.py:629-633`).

**Freeing a volume from the card, and restoring it — `/collections/{id}/offsite/free`, `/offsite/restore` and `/offsite/jobs/{job_id}`.** Freeing removes a received volume's masters and the previews of its RAW masters from the card; thumbnails stay. The image rows keep their paths, and `record_images.master_freed_at` and `preview_freed_at`, each with its size in `master_freed_bytes` or `preview_freed_bytes`, record that the file is stored offsite (`app/core/offsite_free.py:1-7`; `app/models/record.py:222-245`, added by migration `c4e8f1a3b5d7`). `GET /records/images/{img_id}` returns both timestamps (`app/schemas/record.py:222-223`). All four routes are admin-only (`allow_admin`, `app/api/collections.py:61`).

- **The routes.** `GET /collections/{id}/offsite/free` is a dry run: it lists the bucket and changes nothing (`collections.py:345-357`). `POST /collections/{id}/offsite/free` and `POST /collections/{id}/offsite/restore` answer `202` with `{job_id, state, action, status_url}`, the URL being `/collections/{id}/offsite/jobs/{job_id}`, and do the work in a background job (`:360-410`). `GET /collections/{id}/offsite/jobs/{job_id}` returns `{job_id, collection_id, action, state, result, error}`, with `action` `free` or `restore` and `state` `queued`, `running`, `done` or `failed`; a job id that is unknown, or belongs to another volume, is `404` with `"Job not found"` (`:413-425`; `OffsiteJob.to_dict`, `offsite_free.py:933-935`). A finished job is dropped a day (`FINISHED_JOB_TTL`, 24 hours) after it ends, when the next job is reserved, and then answers `404` (`offsite_free.py:938-967`). A queued or running job is not dropped by age. The registry lives in the backend process and each job runs in a daemon thread, so a restart loses every job, a running one included, and its id then answers `404` (`offsite_free.py:1016-1024`).
- **Refusals before a job starts.** Each is a `409` whose `detail` is `{message, ...}` unless noted (`FreeRefused.as_detail`, `offsite_free.py:161-171`; `collections.py:341-342`). In order (`start_free` and `start_restore`, `offsite_free.py:1039-1061`; `_prepare_free`, `:690-711`; `_prepare_restore`, `:895-906`):
  - a free or restore of the volume already queued or running: `"Files of this volume are already being freed or restored. Wait for that to finish."`, with `job_id` (`offsite_free.py:148-150`, `:969-978`; not on the dry run);
  - for a free, the unit in offline mode (The unit's mode, below): `"The unit is in offline mode, so the bucket copy is not kept up and no file on the unit is freed or marked freed. Switch to a mode with the offsite copy to free space."`, with `code` `off_in_this_mode` and `mode`. It is checked before the hold and before the volume is looked up. Neither the dry run nor a restore is refused for it (`OFFLINE_MESSAGE`, `_refuse_offline`, `offsite_free.py:674-687`; `_prepare_free`, `:700`; `plan_free`, `:546-576`);
  - for a free, the upload hold file exists (above): `"Offsite uploads are on hold on this unit while it is being upgraded, so no files can be freed from the card. Try again once the upgrade has finished."`, with `hold_file`. It is checked before the volume is looked up, so it is also the answer for a volume that does not exist. Neither the dry run nor a restore is refused for it (`HOLD_MESSAGE`, `offsite_free.py:144-147`; `_prepare_free`, `:690-711`);
  - a volume that does not exist: `404`, `{message: "Collection N not found"}` (`offsite_free.py:354-362`);
  - no stem: `"This volume has no file name stem, so none of its files are stored offsite and none can be freed or restored."` (`offsite_free.py:118-121`);
  - any image of the volume still in the name-based layout: the `NOT_IN_OWN_FOLDER_MESSAGE` text, which begins `"Some of this volume's files have not yet been moved into the volume's own folder"`, with `folder` (`<stem>/`) and `images_outside_own_folder` (`offsite_free.py:137-143`, `:365-387`);
  - for a free and its dry run, a volume not received (section above): `"Not every file of this volume is verified in the offsite bucket yet, so its files cannot be freed from the card. Wait for the upload to finish."`, with `total`, `verified`, `pending` and `refused` (`offsite_free.py:122-125`, `:397-405`);
  - for a restore, no `DTK_OFFSITE_READ_REMOTE`: `"Restore is not set up on this unit: it needs read access to the offsite bucket (CAPTUA_OFFSITE_READ_REMOTE), and none is configured."` (`offsite_free.py:133-136`, `:901-902`); and a volume directory under a storage root that cannot take writes, `503` with a string `detail` (`:903-905`; `app/main.py:125-128`);
  - the hold for file changes refused: `"An export of this volume is queued or running. Wait for it to finish, then try again."`, or the files-being-read message (`_Hold`, `offsite_free.py:408-422`; `:126-128`);
  - for a free and its dry run, a bucket listing that does not answer: `"The offsite bucket could not be listed, so nothing could be checked against it and nothing was freed. Try again later."`, with `error` (`offsite_free.py:129-132`, `:434-438`).
- **What a free checks, file by file.** The work list is the volume's objects with a verified offsite row that are not yet freed (`_objects`, `offsite_free.py:231-272`). The job checks the stem and the folder again, then refuses, as entries of `result.refused` with a `reason`: an object whose image is in the name-based layout, `outside_own_folder`; a RAW preview whose capture manifests hold no sha256 for it, `no_preview_digest` (its master may still be freed); a file not on disk, `local_file_missing`; one that changed or could not be read while it was hashed, `local_file_unreadable`; and one whose recomputed SHA1 is not its row's `local_sha1`, `local_sha1_differs`, with `local_sha1` and `expected_sha1` (`_free_work`, `:602-627`; `_layout_refusal`, `:275-279`; `_digest_refusal`, `:320-337`). It then lists the bucket again and refuses a key that is not listed, `not_in_bucket`, one listed with no SHA1, `listed_without_sha1`, and one listed with another SHA1, `bucket_sha1_differs`, with `listed_sha1` and `expected_sha1` (`:629-638`; `_listing_refusal`, `:340-347`). A file that passes has its freed state committed under its record's row lock, only while the row still names the same path, and is unlinked after that commit. A row that is gone or changed is refused as `changed`, and a failed unlink clears the state again and is refused as `could_not_remove`, with `error` (`:639-658`; `_set_freed`, `:475-492`). A listing that does not answer during the job fails the job with the listing message (`:990-997`).
- **What a restore does.** For each freed object, the job copies the object from `DTK_OFFSITE_READ_REMOTE` with `rclone copyto --inplace`, one at a time under the upload's transfer lock and `DTK_OFFSITE_BWLIMIT`, to `.<name>.<token>.part` beside the file's path. It checks the copy's SHA1 against the row's `local_sha1`, fsyncs it, and moves it into place with `os.replace` under the record's row lock, clearing the freed state (`_restore_one`, `offsite_free.py:779-830`; `_copy_from_bucket`, `:733-754`; `_place`, `:833-858`). A file already at the path is never overwritten: when its SHA1 is the object's, the state is cleared and the entry carries `already_present: true`; otherwise it is refused as `local_file_differs` (`:791-798`). An object whose image is in the name-based layout when the work list is read stays freed and is refused as `outside_own_folder`, as in a free (`_restore_work`, `offsite_free.py:868-870`). The other refusals are `outside_storage`, `copy_failed` (with `error`), `sha1_differs` (with `copied_sha1` and `expected_sha1`), `could_not_write` (with `error`) and `changed` (`:783-829`). A storage root that becomes unusable stops the job, which fails with that message (`:790`, `:1000-1005`).
- **Results.** A free's `result` is `{collection_id, filename_stem, freed: {files, bytes}, files, refused, manifest}`, each freed file with `image_id`, `kind`, `path`, `key`, `bytes`, `sha1` and `freed_at` (`offsite_free.py:659-671`). A restore's is the same with `restored` for `freed` and `restored_at` on each file (`:875-892`). The dry run returns `{collection_id, filename_stem, would_free: {files, bytes}, files, refused, local_sha1_checked: false}`. For each object it applies, in this order, the layout, preview-digest, listing and missing-file refusals. It hashes nothing, so it never reports `local_file_unreadable` or `local_sha1_differs` (`plan_free`, `offsite_free.py:546-576`). A free writes one line for each file it freed, and a restore one for each file it restored, to `<stem>/metadata/offsite-freed-<UTC>.jsonl` or `offsite-restored-<UTC>.jsonl`; the file is created with its first line, so a run that freed or restored nothing leaves none (`_RunManifest`, `offsite_free.py:495-532`; `:661`, `:877`). A free logs `volume_freed` in the system log only when it freed or refused something, and a restore logs `volume_restored` when it restored or refused something or was stopped. The entry is at `WARN` when anything was refused, and for a restore also when it was stopped, and at `INFO` otherwise (`:664-667`, `:883-888`).
- **A freed file is not missing.** The image routes answer `410` for a freed file, with `detail` `{message, stored_offsite: true, image_id, kind, key, freed_at}` and the message `"This file is stored offsite and has been freed from the card to make room. An admin can restore the volume to bring it back."` (`freed_detail`, `offsite_free.py:151-154`, `:191-206`; `_freed`, `app/api/records.py:970-980`). `GET /records/images/{img_id}/file` answers it for a freed master (`_stored_master`, `:1000-1007`). `GET /records/images/{img_id}/preview` answers it for a RAW master's freed preview, and for any other image whose master was freed; a RAW master's preview is still served when only the master was freed (`:1045-1096`, the RAW branch at `:1062-1066`, the others at `:1067-1068`). `GET /records/images/{img_id}/thumbnail` serves a stored thumbnail as before, and answers `410` only when the thumbnail has to be made again from a freed source (`:1099-1130`). `POST /collections/{id}/export` is refused with `409` and `{message, freed_image_ids}` while any current image's master is freed, with the message `"N file(s) of this volume are stored offsite and freed from the card. Restore the volume before exporting it."`; the export job checks again and fails with `reason: "freed_files"` (`collections.py:1390-1398`; `app/core/export_service.py:176-182`; `offsite_free.py:155-158`). The integrity check lists a freed master under `freed_files`, not `missing_files`, and does not hash it (`app/core/integrity.py:445-466`, `:533`). `GET /collections/{id}/offsite` and the `images` summary count freed files in `freed_files` and `freed_bytes` (`image_upload.py:1475-1480`, `:1541-1542`).

**The capture manifest for Fisqua — `GET /collections/{id}/capture-manifest`.** The route returns the volume's capture manifest, artefact 2 of the exchange contract (section 4, as in 1.1, with the additions of 1.5, 1.6 and 1.9), as a JSON download. Admins and operators may export it (`allow_contributor`); a volume that does not exist is `404` (`app/api/collections.py:428-475`). The manifest is built from the catalogue, the capture manifests and `offsite_objects` only, so no image file is read and the manifest of a freed volume is the same as that of one still on the card (`app/core/capture_manifest.py:1-7`).

- **The response.** `200` with `{contract: "fisqua-captua-exchange", version: "1.9", kind: "capture-manifest", id, generatedAt, generatedBy: {system: "captua", instance: <tenant>, systemVersion}, inReplyTo: null, project: {captuaProjectId, name}, transfer: {channel: "upload", root: "<tenant>/"}, volumes: [...]}`, with a new `id` on every export (`capture_manifest.py:402-422`). `version` is always `"1.9"`, whatever the records and whatever `DTK_FISQUA_ROTATE_DEG` (`VERSION`, `capture_manifest.py:103`; `:69-70`). With `DTK_FISQUA_ROTATE_DEG` set, each image whose `rotate_deg` is `0`, `90`, `180` or `270` also carries `rotateDeg`, that value, counted clockwise from the stored pixels with the EXIF tag ignored; an image with no recorded rotation carries none, and with the setting off no image carries it (`capture_manifest.py:71-78`, `:534-535`). `systemVersion` is the release the unit runs, with the backend's commit appended when the code is not the tagged release (Version reporting, below). The one volume carries `externalId`, `captuaCollectionId`, `stem`, `title` and `records`; each record `captuaRecordId`, `sequence`, `status`, `rejectionNote` (a rejected record's latest comment, or its reason) and `images`, and, where they apply, `missingSide`, `closedReason`, `closedNote` and `requestId` (below; `_record_entry`, `capture_manifest.py:253-271`); each image `captureId`, `pairId`, `filename`, `role`, `objectKey` and `sha256`, and for a RAW image `previewObjectKey` and `previewSha256` (`:415-421`, `:523-533`, `:531-533`). `externalId` is the volume's recorded `external_id`, stripped, or its stem when none is recorded (`reference_code`, `capture_manifest.py:425-428`; `:416`). An image is RAW when its file on disk has a suffix in `RAW_SUFFIXES`, or when the name in its capture key has one, so an adopted object whose key names a RAW is counted as RAW and needs a preview (`:480-484`; `:21-24`). Every record of the volume is listed with its status, in the order of its `sequence`, and only current images (`:25-30`; `:315-321`). A record still `captured` refuses the export (`records_captured`), except an open missing record (below) (`:325-329`). The keys are the frozen keys of the verified objects with the tenant prefix taken off, and `filename` is the last segment of the capture key (`:9-14`). The `sha256` values come from the capture manifests and are never computed here (`:15-20`, `_digest`, `:441-446`). The download name is `capture-manifest_<stem>_<YYYY-MM-DD>.json`, by the UTC date, in `Content-Disposition` (`download_name`, `:614-617`; `collections.py:474-475`). Each export is logged in the activity log as `capture_manifest_exported`, at `INFO`, with the stem as subject and the detail `volume <id> id=<manifest id> records=<n> images=<n> previews=<n>` (`collections.py:470-473`).
- **Missing and excluded records (contract 1.9, section 10.1).** A record with a `missing_side` (Openings and pages never captured, below) is listed with `status` `"missing"`, whatever its status on the unit other than `excluded`, and `missingSide` `left`, `right` or `both`, with its current images: the other page's for a side, none for a placeholder. Once it has been closed it also carries `closedReason` and, when a note was written, `closedNote`. A record `excluded` by a Fisqua decision (contract 1.6) keeps `status` `"excluded"`, and still carries `missingSide` and the closing fields when it has them. A record made from a Fisqua request carries its `requestId`, whatever its status, and still carries it after it has been captured into. A placeholder that has been captured into is an ordinary record and carries no `missingSide` (`_record_entry`, `capture_manifest.py:253-271`; `_request_id`, `:243-250`; `:31-48`). An open missing record, one not closed, does not refuse the export as a captured record does, but its images are listed and must pass every image check (`:325-329`; `:38-43`). Pages are the images of records in review or approved, except an open missing record's: its image is not a page, and a missing record with no image is not refused as `roles_invalid`. A closed missing record in review or approved has its images counted as pages. An excluded record is listed with its current images, is not a page, and its roles are not checked (`:358-368`; `:49-63`). Before 1.9, a record that missed a side was left out of the manifest; it is now listed as `missing`.
- **`409` with problems.** When Fisqua would refuse the file, the route answers `409` with `detail: {message, problems}`. `message` is `"The capture manifest cannot be exported, because Fisqua would refuse it: "` followed by each problem's message, and each problem is `{rule, message, record_ids, image_ids}` (`collections.py:459-466`; `ManifestRefused`, `capture_manifest.py:161-172`; `Problem.as_dict`, `:156-158`). The rules, in the order they are reported, are `tenant_missing`, `tenant_invalid`, `no_stem`, `no_project`, `records_captured`, `sequence_missing`, `sequence_repeated`, `roles_invalid`, `missing_side_contradicted`, `capture_id_missing`, `not_uploaded`, `preview_not_uploaded`, `raw_without_preview`, `upload_refused`, `key_outside`, `filename_form`, `page_key_repeated`, `sha256_missing`, `preview_sha256_missing` and `no_pages` (`RULES`, `:117-138`). The messages of the record-level rules name the records concerned, at most twenty ids, and the fix (`_problems`, `:539-603`; `_ids`, `:143-146`). `tenant_missing`, `tenant_invalid`, `no_stem`, `no_project` and `no_pages` name the fix only (`:286-308`, `:391-395`). `no_pages` is reported when no record in review or approved, other than an open missing record, has an image, and no open missing record that is not excluded remains: Fisqua accepts a delivery whose only records are missing as long as one of them is open (contract 1.9 §10.3, amended). `missing_side_contradicted` refuses a missing record, other than an excluded one, that has an image on its missing side, or any image when it misses `both`: exactly the two clauses of Fisqua's `missing-side` rule (§9.2), so the unit refuses nothing Fisqua would accept (`_contradicts_its_side`, `capture_manifest.py:228-240`).

**Delivery to Fisqua — the `fisqua` object of `GET /collections/{id}/offsite` and `GET /system/catalogue-backup`, and what a handover does.** A unit with Fisqua configured queues the capture manifest of each handed-over volume, sends it over HTTPS once every object of the volume is verified in the bucket, polls Fisqua for the volume's status, and applies Fisqua's QC decisions to the volume's records (`app/core/fisqua_outbox.py`, `app/core/fisqua_decisions.py`, `app/core/fisqua_http.py`). The names on Fisqua's side are in `app/core/fisqua_contract.py`, which names contract version `1.2` (`CONTRACT_VERSION`, `:30`). The manifest document itself declares `version: "1.9"`, whatever its records and settings; `CONTRACT_VERSION` is not sent (`VERSION`, `capture_manifest.py:103`; `:69-70`). `GET /collections/{id}/capture-manifest` is not tied to the configuration. The tables are `fisqua_outbox` and `fisqua_status`, created by migration `9b7087bd0bc5` and extended by `a5f0306a8f8c` and `6df85ec6309b` (`app/models/fisqua.py`).

- **When Fisqua is configured.** The environment is `production` or `staging`, the token is 64 lowercase hexadecimal characters, and the offsite tenant is valid (`fisqua_configured`, `fisqua_outbox.py:173-177`; `TOKEN_PATTERN`, `fisqua_contract.py:21`). Otherwise `fisqua` is `null` on the volume route, nothing is queued, the worker returns `{status: "disabled"}`, and the poll thread is not started (`fisqua_outbox.py:1270-1271`; `FisquaStatusScheduler.start`, `fisqua_outbox.py:1665-1674`). A handover still supersedes, and a take-back still withdraws, the volume's unsent rows. The host is `https://<tenant>.fisqua.org` in `production` and `https://<tenant>.staging.fisqua.org` in `staging`. `DTK_FISQUA_BASE_URL` replaces it only when it is `https://`, or `http://` to `127.0.0.1`, `localhost` or `[::1]`; any other value is ignored with one warning in the journal for each value (`base_url`, `_usable_override`, `fisqua_outbox.py:180-213`; `ENVIRONMENTS`, `fisqua_contract.py:33-36`). The token goes in the `Authorization: Bearer` header only. The transport follows no redirect, verifies TLS, and times out after `DTK_FISQUA_TIMEOUT` seconds to read and write, with 10 seconds to connect (`fisqua_http.py:61`, `:339-346`). `redact` replaces the token with `[token]` in everything the transport returns before a row, a log line or an error text is written, and the settings hold it as a `SecretStr` (`fisqua_outbox.py:238-258`; `config.py:151`). `token_invalid` on the unit summary is `true` when a token is set and is not of that shape; its value is never shown.
- **What a handover does.** `POST /collections/{id}/promote` (`allow_contributor`) that promotes at least one record calls `enqueue_handover` in the same transaction as the status changes: every unsent row of the volume (`waiting_for_upload`, `ready`, `failed`) becomes `superseded`, a row being sent is marked to become `superseded` unless the send delivers or is refused, and, when Fisqua is configured, a `waiting_for_upload` row is added with a new UUID as `manifest_id` (`app/api/collections.py:1212`; `enqueue_handover`, `fisqua_outbox.py:648-677`; `_cancel_sending`, `:771-786`). A promote that finds no captured record to promote, open missing records aside, returns `promoted: 0` and queues nothing. A change to a volume's missing records also queues a handover, when the volume was handed over before (Openings and pages never captured, below). After the commit, `promote` calls `image_upload_scheduler.wake()`, which starts an upload run at once, or one more run after a run in progress, however many wakes arrive; it does nothing when the offsite schedule is not running (`collections.py:1218`; `ImageUploadScheduler.wake`, `image_upload.py:1604-1610`; `_wait`, `:1612-1616`). Each scheduled run uploads first and then runs the Fisqua send pass in the same thread, so a volume received in that run is sent in that run (`tick`, `:1626-1648`). `POST /collections/{id}/take-back` that returns at least one record to `captured` makes the volume's unsent rows `withdrawn`, whatever the configuration, and marks a row being sent the same way (`collections.py:1293`; `withdraw_unsent`, `fisqua_outbox.py:754-768`). A delivered or refused row is left as it is, and nothing is sent to Fisqua on a take-back.
- **The states of an outbox row.** `waiting_for_upload`: handed over, manifest not built, `manifest_id` reserved. `ready`: the manifest is built and stored on the row, so a retry sends the same document. `sending`: claimed by the worker. `delivered`: Fisqua accepted it, with `delivered_at` and, in `external_id`, the `volumeId` Fisqua gave. `refused`: final, with `refusal` `not_exportable` (the unit could not build the manifest; `problems` lists the problems as the capture-manifest route gives them) or `fisqua` (Fisqua refused it; its answer is in `response` and the problems it named in `problems`). `failed`: the last attempt ended in a transient error, in `last_error`, to be tried at `next_attempt_at`. `superseded`: a later handover queued a newer manifest before this one was sent. `withdrawn`: the handover was taken back before this one was sent (`STATES`, `REFUSALS`, `app/models/fisqua.py:45-46`; the descriptions, `:1-37`). The database refuses a `refusal` on a row that is not `refused`, a `delivered_at` on a row that is not `delivered`, and a negative `attempts` (`:51-55`).
- **The reference code at handover.** A volume's reference code is its recorded `external_id` or else its stem. When the recorded `external_id` is not the stem, the row is `refused` at once with refusal `not_exportable` and one problem, `{rule: "reference_code_differs", message, record_ids: [], image_ids: []}`; the model refuses such a pair for every ORM writer, so only a row written before that rule or by raw SQL can reach this (`_reference_problem`, `fisqua_outbox.py:733-751`; `reference_code_differs_problem`, `:124-133`). The worker checks again when it builds the manifest (`:868-876`). A volume with no stem is built at once, with no wait for the bucket, and refused by the builder with the problem `no_stem` (`:864-867`; `capture_manifest.py`).
- **A pass of the worker.** `run_fisqua_outbox` runs after each upload run, in this order (`fisqua_outbox.py:1255-1360`). A row found `sending` was left by a run that did not finish, and becomes `failed`, due at once, with `last_error` `interrupted while sending`, unless a handover or take-back marked it while it was being sent, in which case it becomes `superseded` or `withdrawn`. Under a unit stop with reason `version`, the pass sends the stop's retest manifest when one is due (The configuration stop, below) and, unless that retest removed the stop, returns `config_error`, or `stopped` or `off_in_this_mode` when the retest ended that way (`fisqua_outbox.py:1316-1324`). Each `waiting_for_upload` row is promoted when the volume is received, that is, uploadable and every object verified in the bucket (`_promote`, `:855-897`): the manifest is built under the volume's read hold with the row's `manifest_id`, stored, and the row becomes `ready` with `reference_code` set to the manifest's `externalId`; a manifest the builder refuses makes the row `refused`, `not_exportable`; a volume with files being changed is left waiting. With no transport the pass returns `no_transport`, and with a recorded configuration stop it returns `config_error`. Then each `ready` row, and each `failed` row whose `next_attempt_at` has come, is sent, at most 60 in a pass, each taking one call from a budget of 60 calls a minute shared by every request to Fisqua; when the budget is spent the pass returns `rate_limited` (`MAX_SENDS_PER_PASS`, `CALLS_PER_MINUTE`, `fisqua_contract.py:24-25`; `CallBudget`, `fisqua_outbox.py:587-632`). The pass statuses are `disabled`, `held`, `no_transport`, `config_error`, `rate_limited`, `stopped`, `error`, `off_in_this_mode` and `done`, and the result carries the counts `promoted`, `not_exportable`, `delivered`, `refused`, `failed` and `waiting` (`_Run`, `:841-852`). `off_in_this_mode` means the unit's mode is not `fisqua`: at the start of the pass the result is `{status, mode}` and nothing else, and no call is made; after a switch out of fisqua mode between two sends, or a send the transport refused for the mode, the pass stops with the full result, and the row of the refused send is put back to `ready` with no attempt counted (`:1276-1277`, `:1295-1297`; `_send`, `:1207-1213`).
- **How an answer to the POST is read.** A `2xx` that carries a `volumeId` and names the manifest id sent makes the row `delivered`; any other `2xx` is an error and is retried. `401` and `403` are a configuration stop with reason `token`, `404` with reason `not_found`, and every `3xx` with reason `redirect`; the worker puts the row back to `ready`, not counting the attempt, unless a handover or take-back marked it while it was being sent, in which case it becomes `superseded` or `withdrawn`. `400`, `413` and `422` refuse the manifest for good; a `400` or `413` with no `problems` array is given the local problem `bad-request` or `payload-too-large`. A `409` with a non-empty `problems` array refuses it for good, and a `409` without one is retried. `429`, any `5xx`, any other code, a timeout and a connection error are retried (`read_send_answer`, `fisqua_http.py:122-162`; `REFUSED_ALWAYS`, `REFUSED_WITH_PROBLEMS`, `CONFIG_ERROR`, `fisqua_contract.py:83-97`; `_send`, `fisqua_outbox.py:1176-1252`). A failed send is tried again after `DTK_FISQUA_RETRY_BASE` seconds (300), doubled for each further failure up to `DTK_FISQUA_RETRY_MAX` (21,600), and a longer `Retry-After` from Fisqua replaces that wait; retries never stop (`retry_delay`, `:261-266`). A refusal with `object-missing` problems is logged at `ERR` as `fisqua_object_missing` in the system log, with the stem as subject and each missing key and kind in the detail (`_log_object_missing`, `:929-943`).
- **The configuration stop.** When Fisqua refuses the unit's configuration, the unit stops sending and polling. The stop is the file `fisqua-config-error.json` in `DTK_DATA_DIR`, holding `{at, status_code, reason, config_fingerprint}`, so a restart does not clear it (`record_config_error`, `config_error`, `fisqua_outbox.py:370-542`). It can also hold `retest_at` and `retest_row`, the time of a version stop's last retest and the row that retest sent (`_note_retest`, `fisqua_outbox.py:550-562`), and `rebuild_retest_row` and `rebuild_unsent`, which mark manifests built under a version stop that has been cleared or replaced as still to be built again (`:396-407`, `:427-432`). The reasons are `token`, `not_found`, `redirect` and `version`. `version` is a `400` whose problems include a rule `version`, `envelope` or `shape`: Fisqua cannot read what this software writes. That manifest is refused for good (`_version_refusal`, `fisqua_outbox.py:946-948`; `VERSION_RULES`, `VERSION_REASON`, `fisqua_contract.py:104-105`; `fisqua_outbox.py:1229-1237`). While the stop stands, the pass builds and sends one manifest, a retest, at most once every `_retest_interval`, which is `DTK_FISQUA_RETRY_MAX` seconds (six hours by default), counted from when the stop was recorded or last retested (`fisqua_outbox.py:1114-1117`). The retest sends again, under its id, the row the last retest sent, when that row is `ready` or `failed`; otherwise it takes the first, lowest id first, that is or can now be built: a `ready` row never attempted, a `waiting_for_upload` row, which is built first, or a volume whose newest manifest was refused for `version`, which is handed over again under a new id. A `failed` row of an ordinary send is left out (`_retest_candidates`, `:1022-1048`). No retest is sent, and `retest_at` is left as it was, when the row of the last retest failed and its `next_attempt_at` is still to come, when there is nothing to send, when the call budget is spent, or when a shutdown or a switch out of fisqua mode is under way (`:1118-1122`, `:1144-1149`). When Fisqua reads the retest manifest, that is, accepts it or refuses it for a rule other than `version`, `envelope` or `shape`, the stop is removed and the pass goes on as after an update; when Fisqua refuses it for one of those three rules, the stop is recorded again and the next retest is an interval later (`_retest_version_stop`, `fisqua_outbox.py:1070-1173`; `_retest_interval`, `:545-547`; `:1316-1324`). The stop is removed when the fingerprint changes: the first 8 hexadecimal digits of a SHA-256 of the environment, the base URL in use, the token, the installed code, which is the backend's commit and the release, or the time the process started when no commit can be read, and the `DTK_FISQUA_ROTATE_DEG` setting, so an update clears any stop (`version`, `token`, `not_found` or `redirect`), and where no commit can be read a restart does; sending then resumes, and a stop whose cause remains is recorded again on the next call (`config_fingerprint`, `fisqua_outbox.py:216-235`; `code_identity`, `app/core/version.py:203-208`). After a `version` refusal, a `ready` row with no attempt is put back to `waiting_for_upload` under a new `manifest_id`, and once the stop has cleared, each volume whose newest outbox row is a refusal for `version`, and which has no captured record other than open missing ones, is handed over again under a new id (`_rebuild_unsent`, `_resend_version_refusals`, `_version_refused_volumes`, `fisqua_outbox.py:951-1019`). While any other stop stands, rows are still promoted to `ready` and nothing is sent (`fisqua_outbox.py:1328-1339`).
- **The status poll.** `FisquaStatusScheduler` polls on its own thread, first after `DTK_OFFSITE_BACKUP_DELAY` seconds and then every `DTK_FISQUA_POLL_INTERVAL` seconds (600). A tick's status poll with nothing to ask makes no call. Every tick then runs `sync_fisqua_queue`, which asks Fisqua for the digitisation queue and, before that, sends the operators PUT when it is due: after a send that failed, after a user is created, changed or deleted through the users routes, and at least once a day (`sync_fisqua_queue`, `app/core/fisqua_queue.py:759-862`, the send at `:772`; the rules, `:9-18`). The thread also sends the operators PUT when it starts, before its first wait (`FisquaStatusScheduler`, `fisqua_outbox.py:1650-1727`; `_loop`, `:1685-1694`; `tick`, `:1708-1727`). `main.py` starts it with the other schedules and stops it first (`app/main.py:71-77`). Each volume whose newest sent manifest (`delivered`, or `failed` after at least one attempt) is not final is asked for by the reference code the manifest was sent under, `fisqua_outbox.reference_code`, in batches of at most 100 references to `GET /api/capture/v1/volumes/status?refs=<a>,<b>` (`volumes_to_poll`, `fisqua_outbox.py:1390-1436`; `STATUS_PATH`, `MAX_REFS_PER_CALL`, `fisqua_contract.py:43-46`; `get_status`, `fisqua_http.py:376-388`). Status batches leave 10 calls of the minute's budget for decisions reads, and each tick starts after the last reference asked for, so no batch is starved (`DECISIONS_RESERVED_CALLS`, `fisqua_contract.py:28`; `fisqua_outbox.py:1473-1492`). Fisqua's states are `received`, `registered`, `preparing_review`, `in_capture_qc`, `retakes_requested`, `approved`, `queued`, `running`, `review_pending`, `published`, `refused`, `superseded`, `failed` and `unknown`. A volume is final, and no longer asked for, when its status for its newest sent manifest is `published`, `refused` or `superseded` and no decisions set it offered is unread; `unknown` is not final (`STATES`, `FINAL_STATES`, `fisqua_contract.py:110-116`). An answer is kept in `fisqua_status`. An answer that names the manifest id of a `failed` row, with a state other than `refused`, makes that row `delivered`, so a lost answer to the POST is recovered; a refused one is left to be sent again with the same id (`fisqua_outbox.py:1529-1546`). A `Retry-After` on a status or decisions answer stops polling until it has passed, with status `cooling_down` (`fisqua_outbox.py:1506-1508`). The poll statuses are `disabled`, `held`, `no_transport`, `config_error`, `cooling_down`, `rate_limited`, `error`, `off_in_this_mode` and `done`, and the result carries `asked`, `calls`, `answered`, `changed`, `recovered`, `decisions_fetched`, `decisions_applied` and `decisions_stale` (the `disabled`, `held` and `no_transport` results carry only `status`, and `hold_file` when held) (`fisqua_outbox.py:1439-1557`). `off_in_this_mode` means the unit's mode is not `fisqua`: at the start of the poll the result is `{status, mode}` and nothing else, and no call is made; after a switch out of fisqua mode before a status batch or a decisions read, or a call the transport refused for the mode, the poll stops with the full result (`:1453-1454`, `:1485-1487`, `:1498-1499`, `:1547-1549`; `_fetch_decisions`, `:1603-1606`, `:1622-1624`).
- **The `fisqua` object of `GET /collections/{id}/offsite`.** Its keys are `environment`; `config_error`, `null` or `{at, status_code, reason, config_fingerprint}`; `held` and `hold_file`; `outbox`; `status`; and `decisions` (`volume_fisqua_state`, `fisqua_outbox.py:1742`). `outbox` lists the volume's rows newest first, at most 20, each with `manifest_id`, `stem`, `state`, `created_at`, `attempts`, `next_attempt_at`, `last_attempt_at`, `last_error`, `refusal`, `problems`, `response`, `external_id` and `delivered_at`, and without the manifest (`OUTBOX_LISTED`, `_OUTBOX_FIELDS`, `:137`, `:1737-1739`). `status` is `null` or `{status, status_at, status_checked_at, problems, manifest_id}`, Fisqua's latest word on the volume, with the state as Fisqua gave it. `decisions` is `null` until a set has been seen, and then `{decisions_id, decided_at, applied_at, manifest_id, counts, skipped, rotation_skips, request_skips, reopened, stale}`; `stale` is `true` when the last set offered was for another manifest and was not applied (`decisions_state`, `fisqua_decisions.py:646-663`).
- **The `fisqua` object of `GET /system/catalogue-backup`.** `{configured, token_invalid, environment, config_error, held, hold_file, last_send, last_poll}`. `environment` and `config_error` are `null` while Fisqua is not configured. `last_send` is the result of the last send pass in this backend process and `last_poll` the result of the last poll, each `null` until the first run (`unit_fisqua_summary`, `fisqua_outbox.py:1779-1793`; `ImageUploadScheduler.last_fisqua_result`, `image_upload.py:1579`, `:1645`).
- **Applying Fisqua's QC decisions.** When a status entry carries a `decisionsId` that is neither the set last applied nor one already seen to be stale, the poll reads `GET /api/capture/v1/volumes/<reference>/decisions`, with the reference quoted into the path, taking one call from the budget, and applies the set (`_fetch_decisions`, `fisqua_outbox.py:1581`; `DECISIONS_PATH`, `fisqua_contract.py:129`; `get_decisions`, `fisqua_http.py:390-401`). A volume stays polled while an offered set is unread, even in a final state (`volumes_to_poll`, `fisqua_outbox.py:1415-1417`). `apply_decisions` returns a status: `invalid` (no `decisionsId` or no `records` list), `already_applied`, `pending_handover`, `stale`, `applied` or `error`, which is rolled back (`apply_decisions`, `fisqua_decisions.py:457-643`).
  - A set is applied only when its `manifestId` is the volume's current handover, the newest `delivered` row. A set for another manifest is stale: it is noted, not applied, and logged in the activity log as `fisqua_decisions_stale`. A set is held back as `pending_handover`, unapplied and not stale, while a later row of the volume is `waiting_for_upload`, `ready`, `sending` or `failed`, checked again after the records are locked (`fisqua_decisions.py:486-503`, `:540-545`; `PENDING`, `:162`).
  - Records are locked in id order and each is handled in the one transaction. When the set carries `requests`, every record of the volume is locked in id order and then the volume's row, and a decided record outside the volume is skipped without being locked. A set without `requests` that carries a `missing_page` decision takes the volume's row `FOR UPDATE` after the records and before any status change (`fisqua_decisions.py:513-532`). A record is skipped, with nothing changed, and listed in `skipped` as `{captua_record_id, reason}`, for one of these reasons: `not_in_volume`; `invalid_decision` (not `approved`, `rejected`, `excluded` or `missing_page`, or an exclusion that carries rotations); `invalid_side` (a `missing_page` whose `side` is not `left` or `right`); `invalid_reason` (a rejection whose reason is not one of the nine, or an exclusion with any reason); `note_too_long` (a note over 2,000 characters); `other_without_note`; `captured` (an open missing record stays captured on the unit when its volume is promoted, so a decision for it is skipped here); `images_changed` (the record's current images are not exactly the images the delivered manifest listed for it, compared as capture id, role and object key, so a record retaken since, or one whose pair lost, gained or swapped an image, is not touched); `missing_page_single_record` (a `missing_page` for a record captured in single mode); and `transition_refused` (`_why_not`, `:233-279`; `:548-598`).
  - `approved` moves a record from `in_review` to `approved`, from `rejected` through `in_review`, and leaves an `approved` record as it is. `rejected` moves a record from `in_review` to `rejected` with a rejection row, the reason, the note stripped as the comment and `rejected_by` `Fisqua: <decidedBy>` (`Fisqua` alone when none is given), written by the same function as `POST /records/{id}/reject`; a record already `approved` or `rejected` goes through `in_review` first, and a record already rejected with the same reason, note and reviewer is left as it is. The moves to `approved` and `in_review` go through `_apply_status_change` as a reviewer named `Fisqua: <decidedBy>`, and the rejection through `reject_locked_record`, so every history row names Fisqua (`_apply_one`, `_actor`, `fisqua_decisions.py:287-324`; `reject_locked_record`, `app/api/records.py:1523-1547`).
  - `missing_page` (contract 1.9, section 10.4), with `side` `left` or `right`, is applied by the same function as `POST /records/{id}/missing-page` (Openings and pages never captured, below), and that page is marked missing on the record: a current image of that side is superseded, a record in review or approved is returned to `captured` under the reviewer `Fisqua: <decidedBy>`, and the decision's note, stripped, is kept as `missing_note`. A record already missing that side, or both, is counted as `unchanged`. A closed record that the decision reopens is listed in the report's `reopened` as `{recordId, reason, note}`, the closing it had, and written to the activity log as `missing_record_reopened` under that reviewer (`fisqua_decisions.py:573-585`; `_record_reopened`, `:378-392`).
  - `requests` (contract 1.9, section 10.4), a list beside `records`, is applied after the decisions in the same transaction. For each request of kind `missing_opening`, placeholders are made after its `afterRecordId`, whatever that record's status, `excluded` included: `count` of them, or one when `count` is null, each carrying the request's `expected` and `note`, stripped, and its `requestId`, with `created_by` `Fisqua: <requestedBy>`. The sequences of the records after them are raised, as for `POST /collections/{id}/records/missing-opening`. Each applied request is written to the activity log as `missing_openings_marked`, with `requestedBy` and `requestedAt` in the detail (`_apply_request`, `:431-454`). A request is skipped, and listed in `request_skips` as `{request_id, reason}`, for one of these reasons: `invalid_request` (not an object); `invalid_request_id` (missing, blank, or over 64 characters); `invalid_kind` (not `missing_opening`); `not_in_volume` (`afterRecordId` is not a record of the volume); `invalid_count` (not an integer from 1 to 50); `text_too_long` (`expected` or `note` over 2,000 characters); and `already_applied` (a record on the unit already carries the `requestId`) (`_request_why_not`, `:400-423`; `:600-611`).
  - When the set marked a page missing or made a placeholder, the volume is handed over again in the same transaction under the rule given under Openings and pages never captured, below (`:613-616`).
  - Rotations: each current image of a record decided `approved` or `rejected` takes `rotation_correction_quarter_turns` from the set's `rotations`, matched by `captureId` and `role` (`single`, `left` or `right`), with `quarterTurns` 1, 2 or 3; an image the set lists none for is set to `null`. A rotation that cannot be used is skipped alone and listed in `rotation_skips` as `{captua_record_id, reason}` with `invalid_quarter_turns`, `invalid_role` or `no_such_image`. No file is changed. A `missing_page` or `excluded` decision changes no rotation (`_apply_rotations`, `fisqua_decisions.py:327-351`; `:585`, `:596-597`; `ROTATION_ROLES`, `QUARTER_TURNS`, `fisqua_contract.py:158-159`).
  - The report is kept on `fisqua_status`: `counts` has `approved`, `rejected`, `excluded`, `unchanged`, `skipped`, `rotations`, `rotations_skipped`, `missing_pages`, `placeholders`, `requests_skipped` and `reopened`, beside the lists `skipped`, `rotation_skips`, `request_skips` and `reopened` (`_empty_report`, `fisqua_decisions.py:368-372`; `decisions_state`, `:646-663`). It is recorded in the activity log as `fisqua_decisions_applied`, at `INFO`, with the stem as subject and the detail `volume <id> decisions=<id> approved=<n> rejected=<n> excluded=<n> unchanged=<n> skipped=<n> rotations=<n> rotations_skipped=<n> missing_pages=<n> placeholders=<n> requests_skipped=<n> reopened=<n>` (`:636-642`).
- **Version reporting.** The release is `APP_VERSION` when set, else the first line of the superproject's `VERSION` file, found at `../VERSION` from the backend's working directory, else `unknown` (`release_version`, `app/core/version.py:56-63`). `systemVersion`, in the capture manifest's `generatedBy`, is the release alone when the superproject's HEAD is the commit the tag named for the release points to, annotated tags peeled; otherwise it is `<release>+g<first 12 hexadecimal digits of the backend's commit>`; and the release alone when no commit can be read. A tag known only from inside a pack file counts as absent (`system_version`, `:187-200`; the reading of git files, `:66-184`). The same value is `software.version` in a project's capture manifest (`capture/manifestHandler.py:181-190`). The setting `app_version` (`APP_VERSION`) now defaults to unset; it used to default to `0.0.0-dev` (`config.py:174`).
- **Lines in the journal.** The backend's workers write one line to stderr for each run that did something, at `INFO` or `WARNING` as each worker's rule below says (the handler is the one in Logging, section 8). The image upload: `Image upload run <status>: uploaded=<n> already_present=<n> unverified=<n> refused=<n> conflicts=<n> skipped=<n>`, at `INFO` only when the status is `done`, `stopped` or `held` and nothing was refused, and at `WARNING` otherwise (`image_upload.py:872-883`, the level at `:875` and `:882`). The send pass, when it promoted, built an unexportable manifest, delivered, was refused or failed anything: `Fisqua outbox pass <status>: promoted=<n> not_exportable=<n> delivered=<n> refused=<n> failed=<n> waiting=<n>`, at `INFO` only when the status is `done`, `stopped` or `rate_limited` and nothing was refused or failed (`fisqua_outbox.py:1363-1371`). The poll, when it made a call: `Fisqua status poll <status>: asked=<n> calls=<n> answered=<n> changed=<n> recovered=<n> decisions_fetched=<n> decisions_applied=<n> decisions_stale=<n>`, at `INFO` for `done` and `rate_limited`, and at `WARNING` for any other status (`:1560-1569`, the level at `:1564`). A decisions set applied: `Fisqua decisions <id> applied to volume <id>: approved=<n> rejected=<n> excluded=<n> unchanged=<n> skipped=<n> rotations=<n> rotations_skipped=<n> missing_pages=<n> placeholders=<n> requests_skipped=<n> reopened=<n>`, at `INFO` (`fisqua_decisions.py:631-635`). No line carries the token.

**The unit's mode — `GET /system/unit` and `PUT /system/unit`.** A unit runs in one of three modes, which an admin sets, and keeps a projects setting beside it (NEH-311, NEH-313). Both are stored in `unit_settings`, a table of one row (`id` 1, `check_unit_settings_single_row`) added by migration `d7f9a1c3e5b2`, which only `app/core/unit_mode.py` reads and writes (`app/models/unit_settings.py:1-48`; `alembic/versions/d7f9a1c3e5b2_add_unit_settings.py:38-51`). Changing the mode changes no stored data.

- **The three modes** (`MODES`, `unit_mode.py:76-77`; `check_unit_settings_mode`, `app/models/unit_settings.py:27`, `:46`).
  - `offline`: nothing leaves the unit. The image upload and the catalogue dump each return `{status: "off_in_this_mode", mode}` and list, upload and dump nothing; the dump's sweep of stale local dumps still runs first (`image_upload.py:829-832`; `catalogue_backup.py:710`, `:724-727`). A free is refused (Freeing a volume, above), and so is the `mark-freed` command, with a `ValueError` (`mark_freed`, `offsite_free.py:1087-1090`). The free dry run, restore and the adopt commands, which only read from the bucket, have no mode check (`plan_free`, `offsite_free.py:546-576`; `_prepare_restore`, `:895-906`; `image_upload.py` reads the mode only in `run_image_upload`).
  - `backup`: the image upload and the dump run as configured. No call is made to Fisqua.
  - `fisqua`: the same, and the link to Fisqua: the send pass, the status poll with its QC decisions, the queue sync and the operators PUT (`link_on`, `unit_mode.py:171-173`). Outside fisqua mode each of these returns `{status: "off_in_this_mode", mode}` and makes no call (`run_fisqua_outbox`, `fisqua_outbox.py:1274-1277`; `poll_fisqua_status`, `:1451-1454`; `_gate`, `fisqua_queue.py:195-203`). In fisqua mode volumes come from Fisqua's queue, and operators are restricted (Fisqua mode and volumes, below).
- **When the mode is read.** Each run reads it at its start, after its own configuration checks (`disabled`, `misconfigured`) and before the upload hold, so an offline unit with the hold file in place reports `off_in_this_mode`, not `held`. A run reads it again between objects (image upload), between sends (send pass), and before each batch and each decisions read (status poll), and stops with status `off_in_this_mode` after a switch (`image_upload.py:850-854`; `fisqua_outbox.py:1294-1297`, `:1485-1487`, `:1547-1549`, `:1603-1606`). `HttpFisquaTransport` also checks every request to Fisqua against the stored mode: it reads the mode just before sending and, unless the mode is `fisqua`, sends nothing and returns the outcome `off_in_this_mode`. A mode that cannot be read counts as not `fisqua` (`_mode_refusal`, `app/core/fisqua_http.py:351-361`; `stored_mode_now`, `unit_mode.py:492-507`). The operators PUTs that a change of mode sends are the only requests that skip this check (`get_transport`, `unit_mode.py:479-489`; `fisqua_queue.py:318`). The reference-code lookup does not skip it (`get_lookup_transport`, `unit_mode.py:528-532`, `:566`).
- **What a switch leaves unchanged.** Outbox rows, statuses and records stay as they are. When Fisqua is configured, the backend still queues the manifest of a handover made outside fisqua mode, because `enqueue_handover` does not read the mode, and sends the row once the unit is back in fisqua mode (`fisqua_outbox.py:648-677`; `tests/unit/test_unit_mode.py:1229-1238`). The upload hold applies in every mode.
- **The starting mode.** At start-up, before the schedules, the backend writes the row when there is none: `fisqua` when Fisqua is configured (environment, token and a valid tenant), else `backup` when the offsite upload is configured (remote and a valid tenant), else `offline`, with projects off. It logs `unit_mode_initialised` in the system log, with the mode and the reason in the detail (`initialise`, `unit_mode.py:245-265`; `inferred`, `:134-142`; `_new_row`, `:234-242`; `app/main.py:55-60`). The catalogue dump plays no part in this choice. A stored row is not rewritten at later starts, whatever the configuration says then (`unit_mode.py:255-256`). Until the row exists, the backend answers with the inferred mode and projects off, and writes nothing (`current`, `unit_mode.py:154-159`).
- **Projects.** `projectsEnabled` is the admin's setting, stored in any mode. Projects are shown only when the mode is `offline` and the setting is on (`projects_shown`, `unit_mode.py:129-131`). While they are hidden, the backend puts every new top-level volume into the unit's default project:
  - `POST /collections/` ignores any `project_id` given and puts a volume without `parent_collection_id` into the default project; a volume with a parent is created under its parent, as before. While projects are shown, a request with neither is refused with `400`, as before (`collections.py:136-156`).
  - on `POST /imports/digitisation-list`, the import puts the list's volumes into the default project (Importing a digitisation list, below).
  - the Fisqua queue sync, which runs only in fisqua mode, creates its new volumes there (`fisqua_queue.py:526-528`, `:586-592`).
- **The default project.** The stored `defaultProjectId` when that project still exists; else the unit's only project, when there is exactly one; else the project whose name matches `default` as `_name_key` compares names (stripped, NFC, case-folded), the oldest when several match, and a project named `default` is created when none matches, with no admin needed (`list_import.py:519-525`, `:550-561`, `:586-598`). The choice is stored and logged `default_project_set` in the system log, with the detail `project <id> (<how>)` and the project's name as subject (`default_project`, `unit_mode.py:429-472`). On `POST /collections/`, choosing it can be refused: `503` when the project lock cannot be taken, and `409` with `{message}` when `default` would be the directory of a volume's stem (`collections.py:150-156`). Nothing moves an existing volume (`tests/unit/test_unit_mode.py:821-826`). When the default project is deleted its id is set to null (`ON DELETE SET NULL`, migration `d7f9a1c3e5b2`, line 49), and a project is chosen again by the rule above at the next need.
- **`GET /system/unit`.** Admins, operators and reviewers may read it (`allow_read_only`, `app/api/system.py:24`, `:167-186`). The response is `{mode, projectsEnabled, projectsShown, defaultProjectId, prerequisites}` (`as_api`, `unit_mode.py:207-216`). `defaultProjectId` is `null` until a default project is first chosen. `prerequisites` is `{backup: [...], fisqua: [...]}`, the codes of what the configuration lacks for each mode, read from the configuration alone, with no call to Fisqua (`prerequisites`, `unit_mode.py:192-204`):
  - `offsite_not_configured`: no offsite remote, or no valid tenant (`is_enabled`, `image_upload.py:164-171`);
  - `catalogue_dump_not_configured`: the catalogue dump is not configured, or `DTK_OFFSITE_DUMP_RECIPIENT` is missing or invalid (`unit_mode.py:181-189`, `:199-200`);
  - `fisqua_not_configured`, under `fisqua` only: the link to Fisqua is not configured (environment, token and tenant).

  `fisqua` lists `backup`'s codes as well. An empty list means a switch to that mode can be tried. A switch to `fisqua` also needs the upload hold file to be absent (`unit_mode.py:339-340`) and Fisqua to accept the operators PUT.
- **`PUT /system/unit`.** Admin only (`allow_admin`, `system.py:25`, `:189-214`). The body is `{mode, projectsEnabled}`; both are optional, and a missing or `null` `mode` leaves the mode as it is (`UnitUpdate`, `system.py:160-164`; `unit_mode.py:330`). `mode` is `offline`, `backup` or `fisqua`, and `projectsEnabled` a boolean. Any other key, or any other mode, is refused with FastAPI's validation `422` (`extra="forbid"`, `system.py:161`; `tests/unit/test_unit_mode.py:498-499`, `:1196-1198`). The response is the `GET /system/unit` body. A change of mode is checked in this order (`change`, `unit_mode.py:308-387`):
  - a switch to `backup` or `fisqua` with missing prerequisites is refused, with one problem for each missing one (`:334-337`). A switch to `offline` needs nothing;
  - a switch to `fisqua` while the upload hold file exists is refused with `offsite_held`, and nothing is sent (`:339-340`);
  - a switch to `fisqua` sends Fisqua the operators PUT with `mode: "fisqua"`, and is refused with `fisqua_unreachable` when Fisqua does not accept it (`:341-345`);
  - a switch down from `fisqua` sends the operators PUT once, with the new mode, best effort: a failure does not stop the switch, and `unit_mode_changed` is then logged at `WARN` with `; Fisqua not told: <error>` in its detail (`:346-355`, `:378-383`). A change between `offline` and `backup` sends nothing (`tests/unit/test_unit_mode.py:478-482`);
  - when another change was committed after this request first read the row, the request is refused with `mode_changed` and stores nothing. The check compares both the mode and `projects_enabled`, so a request that changes only `projectsEnabled` can be refused this way too (`unit_mode.py:357-364`). When this request told Fisqua a mode, on a switch to `fisqua` or on a down-switch whose PUT succeeded, and the stored mode differs from it, the backend sends the stored mode at once and logs `unit_mode_resent` (`:345`, `:350-351`; `_resend_stored`, `:390-414`). The backend does the same when the commit fails, and the error is then raised (`:374-377`).

  A refusal is `409` with `detail` `{message, problems}`, and nothing is stored, `projectsEnabled` included (`ModeRefused.detail`, `unit_mode.py:289-305`; `system.py:212-213`; `tests/unit/test_unit_mode.py:408-415`). `message` is `"The unit cannot switch to <mode> mode."`. Each problem is `{code, message}`, the messages fixed in `PREREQUISITE_MESSAGES` (`unit_mode.py:95-102`), and a `fisqua_unreachable` problem also carries `error`, which begins with the outcome (`not_configured`, `config_error`, `rate_limited`, `unsupported`, `refused` or `error`) and never holds the token (`send_operators_with_mode`, `fisqua_queue.py:314-354`; `tests/unit/test_unit_mode.py:436-447`). The codes are `offsite_not_configured`, `catalogue_dump_not_configured`, `fisqua_not_configured`, `offsite_held`, `fisqua_unreachable` and `mode_changed`. Each change is logged in the system log, category `system`: `unit_mode_changed` with the detail `<old> -> <new>`, and `unit_projects_changed` with `projects_enabled <old> -> <new>` (`unit_mode.py:378-386`).
- **Fisqua mode and volumes.** In fisqua mode volumes come from Fisqua's queue.
  - An operator is refused with `403` and `detail` `{code: "volumes_from_fisqua", message}`, the message `"In Fisqua mode, volumes come from Fisqua's queue. Only an admin can create a volume, change its file name stem or reference code, or import a list."` (`VOLUMES_FROM_FISQUA_MESSAGE`, `unit_mode.py:105-108`). The refusal is made on `POST /collections/` after FastAPI's validation of the body and the role check, and before any other check in the route body (`collections.py:107-134`); on `PATCH /collections/{id}` that sets `filename_stem` or `external_id` to a value other than the stored one, clearing included (`:545-554`, `:576-578`); and on `POST /imports/digitisation-list`, before the file is read (`imports.py:117-120`). A `PATCH` of other fields, or one that repeats the stored stem, is accepted (`tests/unit/test_unit_mode.py:536-542`).
  - An admin's new volume, top-level or nested, and an admin's change of stem or `external_id`, are saved only after Fisqua has confirmed each new code, with one `GET /api/capture/v1/descriptions/{code}` (contract 1.8) for each distinct value: the stem and any `external_id` of a new volume, the changed values of a `PATCH` (`collections.py:147-148`, `:558-560`, `:579-586`; `check_reference_codes`, `unit_mode.py:602-609`; `DESCRIPTIONS_PATH`, `app/core/fisqua_contract.py:247`). They are logged `volume_created_override` and `volume_code_override`, at `INFO` in category `activity`, with the stem and `external_id` in the detail (`collections.py:201-205`, `:712-718`; `tests/unit/test_unit_mode.py:894-908`).
  - An admin's `PATCH` that clears the stem is refused with `422` and `{code: "stem_required", message}`, the message `"In Fisqua mode a volume's file name stem is its Fisqua reference code, so it cannot be empty."` (`collections.py:555-557`, `:572-575`; `STEM_REQUIRED_MESSAGE`, `unit_mode.py:103`). Outside fisqua mode the rules under A volume's identity, above, apply.
  - An admin may import a list, with no lookup; the import is logged `list_import_override` with the list id and the reference code and id of each volume created (`imports.py:149-156`; `tests/unit/test_unit_mode.py:630-638`).
  - **The lookup's refusals.** Each `detail` is `{code, message, referenceCode}`, with `error` on the `409`s, and nothing is saved (`CodeRefused.detail`, `unit_mode.py:521-525`; `check_reference_code`, `:535-599`):
    - `422` `unknown_reference_code`, `"Fisqua has no description with the reference code <code> in this workspace."`: Fisqua answered `404` with the rule `unknown-reference-code`, or a `2xx` whose `referenceCode` is not exactly the code asked for (`read_description_answer`, `fisqua_http.py:278-279`; `unit_mode.py:583-590`);
    - `409` `fisqua_no_lookup`, `"This Fisqua cannot check reference codes (contract 1.8). A list file exported from Fisqua can be imported instead."`: any other `404`, or a `405`, with `error` `unsupported: HTTP <status>` (`fisqua_http.py:280-282`; `unit_mode.py:591-593`);
    - `409` `fisqua_unreachable`, `"Fisqua could not be reached to check the reference code <code>. A list file exported from Fisqua can be imported instead."`: the request was not sent, or Fisqua's answer could not be used. `error` names the cause (`unit_mode.py:554-572`, `:581-582`, `:594-599`): `not_configured`, Fisqua is not configured; `held`, the upload hold file exists; `config_error: ...`, the link's configuration stop is in place; `cooling_down`, the link is waiting out a `Retry-After`; `rate_limited`, the call budget is spent; `off_in_this_mode: ...`, the unit was switched out of fisqua mode before the request was sent, so the transport sent nothing (`fisqua_http.py:351-361`); `unreadable: ...`, a `2xx` object with no string `referenceCode` (a `2xx` that is not an object gives `error: ...`, `fisqua_http.py:274-276`); `error: ...`, a network error or timeout, or an answer such as `429`, which gives `error: Fisqua answered HTTP 429` (`fisqua_http.py:116-119`); `config_error: ...` also follows a `401`, `403` or redirect, which the backend records as the link's configuration stop. A `Retry-After` on the answer puts the link into its cooldown, as on the link's other calls.

**Importing a digitisation list — `POST /imports/digitisation-list`.** The route reads artefact 1 of exchange contract 1.1 and creates one volume per item; the route is in `app/api/imports.py` and the import in `app/core/list_import.py`. The request is a multipart upload with one field, `file`, carrying the list file unchanged. Admins and operators may import; in fisqua mode only admins may (The unit's mode, above). Creating a project is admin-only, as on `POST /projects/`, so while projects are shown a list whose project does not exist yet is refused to an operator with `403` before anything is written. While projects are hidden the import puts the volumes into the unit's default project, and this refusal is not made (`list_import.py:836-840`).

- **Refused whole, with no volume or report written.** A file over 10 MiB (10,485,760 bytes) is refused with `413` (`imports.py:80-81`). A file that is not strict UTF-8 JSON (not UTF-8, not JSON, `NaN` or `Infinity`, a key repeated within one object, nesting too deep, a number too large to read) is refused with `400` (`parse_list_file`, `list_import.py:243-278`). So is a file in which any key or string holds an escaped lone surrogate, such as `\ud800`; an escaped surrogate pair is one character and is accepted (`_holds_lone_surrogate`, `:223-240`; `:273-277`). An envelope this unit does not read is refused with the application's `422`: a top-level value that is not a JSON object (`list_import.py:347-348`), a `contract` other than `fisqua-captua-exchange`, a `kind` other than `digitisation-list`, a `version` whose major is not `1`, an `id` that is not a UUID, a missing or blank `list.name`, one containing NUL (`:369-371`), or one longer than 255 characters once stripped and in NFC (`:372-373`), or `items` that are not a list (`check_envelope`, `list_import.py:340-377`). Unknown fields are ignored. A list id imported before from a file with a different SHA-256, or whose earlier hash cannot be read, is refused with `409`; a first import whose hash cannot be recorded, with `503` (`_check_hash`, `list_import.py:992-1038`). A list that would create a project is also refused with `503` when the lock an import takes to look for and create its project when none exists, `<DTK_DATA_DIR>/imports/.project-create.lock`, cannot be taken; the detail is `"Captua could not take the lock that keeps two imports from creating the same project, so it did not import the list. Try again."`, and no project or volume is written. A list whose project exists is imported without that lock (`_project_for`, `list_import.py:564-600`, the lock at `:594-600`; `:281-313`; `imports.py:137-138`). Each body is `{detail}` with a string.
- **The project refusals and the list's hash.** Inside the list lock's block, whether or not the lock file could be made, and before the list's hash is written, `_refuse_list_before_hash` refuses the whole list when no project matches its name: from an operator with `403`, and from an admin with `422` when the project it would create would have a volume's stem as its directory name (`list_import.py:846`, `:966-979`). A refused file therefore leaves no hash, and a corrected file can be imported under the same list id. If `_project_for` fails after the hash was written, for any reason (a refusal, the project deleted between the check and its use, the project lock not taken, or a database error), the hash is removed when this run wrote it and holds the lock (`list_import.py:851-873`). Without the lock the hash is kept and a WARNING names its path; a corrected file under that id is then refused with `409` until the hash file is removed by hand. A hash that an earlier import recorded is never removed (`:864-872`; `_remove_hash_file`, `:982-989`, which logs a removal that fails).
- **The project.** While projects are hidden, the volumes are created in the unit's default project, whoever imports; `list.notes` is not stored on it, `projectNotesSkipped` is `"default_project"`, and `projectCreated` says whether this import created the default project (`list_import.py:825-880`; The unit's mode, above). The operator's `403` and `_refuse_list_before_hash` are then skipped (`:839`, `:845-846`), but choosing the default project can still refuse the list after its hash is written: with the application's `422` when `default` would be the directory of a volume's stem (`ListRefused`, `list_import.py:614-617`; `imports.py:131-132`), and with `503` when the project lock cannot be taken (`ProjectLockUnavailable`, `list_import.py:594-596`; `imports.py:137-138`). The hash is then removed as the bullet above describes (`list_import.py:856-873`). While projects are shown, the volumes are created directly under the project whose name matches `list.name`, compared stripped, in NFC and case-folded, with accents kept (`_name_key`, `list_import.py:519-525`; `_find_project`, `:550-561`); if several match, the oldest. If none matches, a project is created, and `list.notes` becomes its description when it is a non-blank string of at most 10,000 characters with no NUL (`notes_skip_reason`, `list_import.py:532-547`; `:608`). An existing project's description is never changed (`_project_for`, `list_import.py:564-600`).
- **The mapping.** `referenceCode` to `external_id`, `filenameStem` to `filename_stem`, `title` to `name`, `dates.display` to `date`, `dates.start` to `date_start`, `dates.end` to `date_end`, `sequence` to `sequence`. Every other item field, `containerPath` included, is stored in `custom_attributes` as a JSON string under a `fisqua` key, and `dates` subfields other than those three under `fisqua.dates` (`list_import.py:498-511`). No records are created.
- **Items are skip-and-report.** Each item is checked, then created and committed on its own, so no item is rolled back because another was rejected. The first failing check gives the reason, in this order: the item is not an object; the reference code is missing, not a string of at most 255 characters, padded with whitespace, or repeated earlier in the list; the stem is missing, not a slug, longer than 27 characters, not equal to the reference code, or repeated earlier in the list; the title is missing or invalid; the dates are invalid or end before they start; the sequence is not a 32-bit integer; a volume on the unit already has the reference code, or the stem (`_check_item`, `list_import.py:425-511`, and `:675-678`). A constraint violation at the insert or the commit is mapped by constraint name to the same reasons, or else to `refused_by_database`. The stem directory check at the insert gives two more: `filename_stem_is_project_directory` when the stem is a project's directory name, and `filename_stem_directory_occupied` when `<projects root>/<stem>/` already holds files (`list_import.py:142-156`, `:687-691`), and the stem check against offsite keys a third, `filename_stem_held_offsite` (`:147-149`, `:692-696`). Any other database failure on an item, in the two duplicate lookups, the insert or the commit, rejects that item as `refused_by_database`, and the import and its report go on (`:702-708`). The reason codes and their messages are `REASONS` and `_CONSTRAINT_REASONS` (`list_import.py:120-166`). The reference code is never stripped. The import refuses a mismatched item before the database, as `filename_stem_differs_from_reference_code`; `POST /collections/` and `PATCH /collections/{id}` refuse the same pair at the flush with `409` (above, A volume's reference code is its stem).
- **The report.** The response is `200` with the report: `listId`, `listName`, `projectId`, `projectName`, `projectCreated`, `projectNotesStored`, `projectNotesSkipped`, `importedAt`, `importedBy`, the counts `created` and `skipped`, `volumes` (each created volume's `position`, `referenceCode`, `filenameStem` and `captuaCollectionId`), `rejects` (each rejected item's `position`, `referenceCode` cut to 120 characters, `referenceCodeTruncated`, `reason` and `message`), `fileSha256`, `listStored` and `reportStored` (`list_import.py:746-760`, `:881-896`). The report is also written, without `reportStored`, to `<DTK_DATA_DIR>/imports/<list-id>/import-report_<list-id>_run<NNNN>.json`, one numbered file per run, none overwritten (`store_report`, `list_import.py:1444-1491`). If that write fails, `reportStored` is `false` and the volumes stay created. `listStored` is `true` when the uploaded file was kept, byte for byte, as `<DTK_DATA_DIR>/imports/<list-id>/list.json`, and `false` when it could not be written; the volumes stay created either way, and `listStored` is stored with the report (`import_list`, `list_import.py:882-889`; `store_list_file`, `:1106-1130`). `GET /imports/digitisation-lists` reads a list's items from that file (below). The client's `ImportReport` declares the field, and the queue page shows a warning when it is `false` (`frontend/src/lib/api.ts:1887-1889`; `frontend/src/routes/(dashboard)/dashboard/queue/+page.svelte:521-523`). The list's hash is kept beside the runs in a file named `sha256`. `GET /imports/digitisation-list/{list_id}/report` (admin, operator or reviewer) returns the highest-numbered run that parses as the list's report, as an attachment named `import-report_<list-id>.json`; an id that is not a UUID is refused with `422`, and a list with no readable report with `404` (`imports.py:305-324`). Each completed import is recorded in the activity log as `digitisation_list_imported`, at `WARN` when the report could not be stored; a refused import is not logged (`imports.py:142-148`).
- **Re-importing.** The same file can be imported again. Every item already on the unit is rejected as `reference_code_on_unit` (or `filename_stem_on_unit`), any other item is checked and created as on the first run, and the report is stored as the next run. A different file under the same list id is refused with `409`. Imports of one list id are serialised by an exclusive lock on `<DTK_DATA_DIR>/imports/<list-id>/.lock` (`import_list`, `list_import.py:789-896`; `_list_lock`, `:915-950`); if the lock file cannot be created, the import runs unlocked and the failure is logged (`:932-940`). A re-import finds its project by name (`_find_project`, `:550-561`), so after the project has been renamed an operator's re-import is refused with `403`, and an admin's creates a new project.
- **Imported lists — `GET /imports/digitisation-lists`.** Admins, operators and reviewers may read the lists (`allow_read_only`, `imports.py:61`). The route takes no query parameters and writes nothing. The response is `200` with an array of every list imported on the unit, newest `importedAt` first, followed, in order of id, by the lists with no readable report (`list_digitisation_lists`, `imports.py:160-233`; `stored_lists`, `list_import.py:1182-1238`). A list is a directory under `<DTK_DATA_DIR>/imports/` named by a UUID that holds a readable report, a `list.json` readable as that list, or both; a directory with neither is left out, and when the `imports/` directory cannot be read the response is `[]`. The digitisation queue synced with Fisqua is one of the lists.
  - Each list has `listId`; `source`, `queue` for the digitisation queue and `file` for an imported file; `listName`, `projectId` and `importedAt`, from the latest report, or, without one, `listName` from the file and the other two `null`; `listFileMissing`, `true` when `list.json` is missing, cannot be read, or is another list's file; and `items`, which is `[]` when `listFileMissing` is `true`.
  - The items are in list order: by `sequence`, items without an integer `sequence` after those with one, then by position in the file. An item that is not a JSON object is left out. Each item has `position`, counted from 1 in the file; `sequence`; `referenceCode`, `filenameStem`, `title`, `notes`, `action`, `assignee` and `itemId`, each the file's string or `null`; `withdrawn`, `true` only when the item holds `true`; and `retakes`, the item's list or `[]` (`_list_items`, `list_import.py:1133-1179`).
  - The route adds to each item `collectionId` and `projectId`, the id and project of the volume on the unit whose `filename_stem` is the item's `filenameStem`; `status`, that volume's record counts by status (`captured`, `in_review`, `rejected`, `approved` and `excluded`), as `GET /activity/collections` gives them; `doneMark`, `{by, at}` when the item was marked done with `PUT /imports/digitisation-lists/{list_id}/items/{position}/done`, otherwise `null`; and `queueHidden`, `true` when that volume's `queue_hidden_at` is set. A stem is looked up only when it is a slug of at most 27 characters, the first of the import's stem checks (`stem_is_well_formed`, `list_import.py:393-399`; `imports.py:201-202`, `:221`, `:226`); an item whose stem passes that check can be given a volume even when the import would refuse the item for another reason. A stem's volume is given to one item of the list: the first, by position, that is not withdrawn, or the first withdrawn one when no live item names the stem. Every other item has `collectionId`, `projectId` and `status` `null`, as does an item whose stem no volume has (`imports.py:198-233`; `StatusCounts`, `app/schemas/activity.py:10-18`). The done marks are read from `done.json` in the list's directory, by position for a file's list and by `itemId` for the queue; a missing or damaged file is read as no marks (`read_done_marks`, `list_import.py:1318-1344`).
  - The route raises no error of its own. A request without a valid token is refused with `401`, and one from a role outside the three with `403`, by the role check.
  - The client calls it as `importsApi.lists()` (`frontend/src/lib/api.ts:1905-1907`).

**A record's rejection — `POST /records/{id}/reject`.** A reviewer or admin rejects a record that is `in_review` (`allow_reviewer`, `app/api/records.py:1550-1556`). The body is `{predefined_reason, comment}`. The response is `200` with the record, now `rejected`. Every current image is linked to the rejection, and `GET /records/{id}/rejections` lists the rejections, newest first, each with the images it flagged (`records.py:1523-1547`, `:1570-1583`, `:1790-1808`).

- **The reasons.** `predefined_reason` is one of nine values: `blur`, `glare`, `shadow`, `focus`, `exposure`, `dirt`, `framing`, `obstruction` and `other`. `framing` is a page cut off or badly framed, and `obstruction` is a finger, weight or object in the shot (`PredefinedRejectionReason`, `app/schemas/record.py:86-100`). Any other value is refused with FastAPI's validation `422`. The `record_rejections` table admits the same nine in the check constraint `check_record_rejection_reason`, widened from the first six by migration `a8c2e4f6b1d3` (`app/models/record.py:300-306`). On `GET /records/{id}/rejections`, `predefined_reason` is a plain string, so rows written before the migration are returned unchanged.
- **The comment.** `comment` is at most 2,000 characters for every reason, counted as sent: a longer one is refused with the validation `422` and the message `"Value error, A rejection comment can be at most 2,000 characters long."` inside the `detail` array, and nothing is written (`REJECTION_COMMENT_MAX_LENGTH`, `app/schemas/record.py:335-339`; `_comment_fits_fisqua`, `:346-351`). Within that, `comment` is optional for the first eight reasons. For `other` it must hold text other than whitespace: a request without one, or with `null`, an empty string or whitespace only, is refused with `422` and nothing is written (`RecordRejectRequest._other_needs_a_comment`, `schemas/record.py:353-359`). This is the validation `422`, a `detail` array whose message reads `"Value error, A rejection with reason 'other' needs a comment saying what is wrong."`, not one of the application's own. The table does not check the comment, because rows written before the migration carry none (`alembic/versions/a8c2e4f6b1d3_rejection_reasons_framing_obstruction_other.py`).
- **Other refusals.** A record that does not exist is `404` with `"Record not found"`. A record whose status is not `in_review` is `422` with a string `detail` naming the status (`records.py:1570-1577`).
- **Downgrade.** `downgrade()` in `alembic/versions/a8c2e4f6b1d3_rejection_reasons_framing_obstruction_other.py` is refused while any rejection uses `framing`, `obstruction` or `other`, and no reason is rewritten; those rows are removed by hand first.

**Recaptures and the recapture turn — `GET /records/to-retake/summary`.** While records are pending anywhere on the unit, starting a new volume alternates with finishing recaptures (`app/core/recapture_turn.py:1-66`). A record is pending while its status is `rejected`, or while it is `captured` and a current image still carries a `rejection_id`, the state `PATCH /records/{id}/status` leaves a record prepared for retake in until a capture replaces the image; or while it misses a page or a whole opening (`missing_side` set), has not been closed (`closed_reason` null) and is not `excluded`, until a dual capture into it writes both pages or it is closed with `POST /records/{id}/close-missing` (Openings and pages never captured, below) (`retake_clause`, `open_missing_clause`, `missing_side_clause`, `pending_clause`, `recapture_turn.py:126-148`; `pending_reason`, `record_is_pending`, `:164-177`). That one definition is used by the summary, the list, the count, the turn and the completion test. The promotion refusal counts only the first two states (below).

- **The summary.** Any signed-in role (`allow_read_only`, `app/api/records.py:388-465`). The response is `200` with `{pendingRecords, volumes, turn}`. `pendingRecords` counts the unit's pending records. Each volume with at least one pending record is listed as `{collectionId, projectId, name, filenameStem, pending, total, excluded, firstPendingRecordId, pendingRecordIds, missingSideRecordIds}`, most pending first, then by name: `pending` is its pending records, `total` its records with at least one rejection whatever their state now, except excluded ones, `excluded` its records excluded by a Fisqua decision (contract 1.6), which are never pending, `pendingRecordIds` its pending records by sequence (a record with none last) and then id, `firstPendingRecordId` the first of them, and `missingSideRecordIds` those of them whose pending reason is `missing_side`, in the same order, so a rejected record that also misses a side is not among them (`records.py:436-437`). A record pending only because it is missing, such as a placeholder, has no rejection, so it counts in `pending` and not in `total`; a record rejected earlier and later marked missing counts in both. `projectId` is the project that owns the volume, through its parents for a nested one. `GET /records/to-retake/count` returns `{count}`, the number of pending records on the unit, the same set the list returns (`records.py:378-385`).
- **The list.** `GET /records/to-retake`, any signed-in role, returns every pending record on the unit (`records.py:292-375`). Records are ordered by volume, by its stem (volumes without one after every volume with one), then its name and id, so records in no volume come last; within a volume, by `sequence` (records without one last) and then id. Each row is `{recordId, title, sequence, collectionId, projectId, name, filenameStem, reason, comment, rejectedBy, rejectedAt, pendingReason, missingSide, missingExpected, missingNote, requestId}` (`RecordToRetake`, `app/schemas/record.py:377-405`). `reason`, `comment`, `rejectedBy` and `rejectedAt` come from the record's latest rejection and are `null` when it has none, as a placeholder has none. `pendingReason` is `rejected`, `prepared` or `missing_side`, checked in that order, so a rejected record that also misses a side is `rejected` (`pending_reason_clause`, `recapture_turn.py:151-161`). `missingSide`, `missingExpected`, `missingNote` and `requestId` are the record's `missing_side`, `missing_expected`, `missing_note` and `missing_request_id`. A closed missing record is not pending and is not listed.
- **The turn.** `turn` is `{state, unlockedBy}` (`turn`, `recapture_turn.py:297-321`). `state` is `free` when no record is pending; otherwise `new` when the newest `recapture_volume_completed` or `rescan_volume_completed` event in the system log is newer than the newest `new_volume_started` (`_COMPLETION_ACTIONS`, `recapture_turn.py:83`, read at `:308-310`), and `recaptures` when it is not or there is none. Newer means a higher `system_logs.id`. `unlockedBy`, for `new` only, is `{collectionId, name}` of the volume whose completion opened the turn, by its current name, or the name the event recorded when the volume has been deleted; otherwise `null`. Turns do not accumulate: two completions in a row open one turn.
- **The two events.** Both are system-log rows with category `capture`, the volume's name as subject and the detail `collection_id=<id> filename_stem=<stem>`, added to the capture's own transaction, so each stands or falls with its capture (`record_event`, `recapture_turn.py:324-338`; `_record_turn_events`, `app/api/cameras.py:122-148`). `new_volume_started` is written for a capture that creates the first record of a volume with none, except the first capture of a full rescan, which writes none (`cameras.py:114-115`, `:140-141`). `recapture_volume_completed` is written for a retake of a pending record that leaves its volume with no pending record, once each time the volume reaches zero, and never for a status change alone. A retake in a full rescan whose volume has no `rescan_volume_completed` event yet writes none (`cameras.py:145-148`). `POST /records/{id}/close-missing` writes it in the same way, in its own transaction, when the record it closes was pending and the volume is left with none (`records.py:1757-1767`).
- **The capture refusal.** `POST /cameras/capture` and `POST /cameras/capture/dual` refuse a capture that is not a retake, into a volume with no record, while the turn is `recaptures`, unless the user is an admin: `409` with `detail` `{code: "recapture_turn", message: "The volume could not be started: it is the retake turn. Finish the retakes of one volume and try again."}` (`_refuse_a_new_volume_out_of_turn`, `cameras.py:97-119`; `RECAPTURE_TURN_DETAIL`, `recapture_turn.py:91-97`). It runs after the refusals listed under A capture needs a volume with a stem, before any capture number is taken or camera touched (`cameras.py:870`, `:1122`). Retakes, captures into a volume that already has records, and the first capture of a full rescan are never refused by it (`cameras.py:112-115`).
- **Locking.** A capture that starts a volume, and a retake of a pending record, take the unit's turn lock, a PostgreSQL transaction-level advisory lock (`pg_advisory_xact_lock`, key `0x43415054`), after the record and volume row locks they already hold, and keep it until the capture commits, so two operators cannot both start a new volume on one completion. The first takes it before reading the turn, the second before the completion count; any other capture takes none (`cameras.py:116`, `:143`; `lock_turn`, `recapture_turn.py:102-110`). `POST /records/{id}/close-missing`, when the record it closes was pending, takes the record's row, then the volume's row, then the turn lock, before the completion count (`records.py:1754-1767`). On SQLite, used only by the test suite, no lock is taken.
- **The promotion refusal.** `POST /collections/{id}/promote`, which admins and operators may call (`allow_contributor`), refuses a volume with any record waiting for a retake whoever calls it, that is, a record `rejected`, or `captured` with a current image that carries a `rejection_id`: `409` with `detail` `{code: "recaptures_pending", pending: <n>, message: "The volume could not be sent to review: <n> retakes left."}`. The count is taken after the record locks and before the idempotent return, so a volume whose only records left are rejected is refused too (`volume_retakes_pending`, `recapture_turn.py:194-200`; `app/api/collections.py:1151-1170`). An open missing record is pending but does not refuse the promotion: it is not promoted, stays `captured`, and is listed as `missing` in the manifest; a closed one is promoted like any captured record (`collections.py:1139-1150`). `PATCH /records/{id}/status` refuses to move an open missing record from `captured` to `in_review`, with `422` and `"Record N misses both pages. Capture the opening, or close it as not to be captured, before handing it over."` (or `its left page`, `its right page`), and `POST /records/bulk-status` skips it (`_assert_promotable`, `records.py:1305-1355`). After the record locks and before any status change, every promotion takes the volume's row `FOR UPDATE` once, so a promotion locks the records, then the volume's row, and then writes the history rows and the outbox row (`collections.py:1196-1212`).

**Openings and pages never captured — `POST /collections/{id}/records/missing-opening`, `POST /records/{id}/missing-page` and `POST /records/{id}/close-missing`.** Under exchange contract 1.9, section 10, a record can stand for an opening, or one page of an opening, that was never captured. Such a record is pending (Recaptures and the recapture turn, above) until a dual capture into it writes both pages, or until an operator closes it as not to be captured. All three routes are for admins and operators (`allow_contributor`).

- **The record fields.** `RecordRead` carries six fields for this (`app/schemas/record.py:292-304`). `missing_side` is `left` or `right` for a dual record that misses that page, whose one current image, if it has one, is the other page; `both` for a record with no image, a placeholder; otherwise `null`. `missing_expected` is what a placeholder should hold, and `missing_note` a note on the missing record. `missing_request_id` is the Fisqua request a placeholder was made from, kept after the placeholder has been captured into. `closed_reason` is why the record was closed without being captured, one of `foliation_skip`, `leaf_missing_from_volume`, `captured_elsewhere` and `other`, and `closed_note` the note given with it. Check constraints admit no other `missing_side` or `closed_reason` value, and no `closed_reason` on a record with no `missing_side` (`app/models/record.py:74-101`, `:133-145`; migration `c4e6a8b0d2f4`).
- **`POST /collections/{id}/records/missing-opening`.** The body is `{afterRecordId, count, expected, note, requestId}`, and only `afterRecordId` is required. `count` is 1 to 50, and one when null or absent; `expected` and `note` are at most 2,000 characters, and `requestId` at most 64. A value outside these limits is FastAPI's validation `422` (`MissingOpeningsCreate`, `app/schemas/record.py:412-419`). The route inserts `count` placeholders right after the record named, whatever its status, `excluded` included. Each placeholder is a dual record of the volume, `captured`, with no image, `missing_side` `both`, and the body's `expected`, `note` and `requestId` (`insert_placeholders`, `app/core/record_sequence.py:207-233`). The placeholders are given the sequences right after that record, and the sequences of the later records are raised by `count` (A record inserted after another, above). The response is `200` with the placeholders, in order, as `RecordRead`. A volume or a record that does not exist is `404`, with `"Collection N not found"` or `"Record N not found"`. A record of another volume is `422` with `"Record N is not in volume M, so no opening can be marked after it there."`. A volume whose records keep changing gives the renumber's `409` (`app/api/collections.py:954-1020`). The insertion is recorded in the activity log as `missing_openings_marked`, with the detail `volume <id> after <record id> count=<n> requestId=<id> records=[<ids>]`.
- **`POST /records/{id}/missing-page`.** The body is `{side, note}`: `side` is `left` or `right`, and `note` is optional and at most 2,000 characters (`MissingPageRequest`, `app/schemas/record.py:422-425`). A record captured in single mode is refused with `409` and `detail` `{code: "missing_page_single_record", message}`, and nothing changes (`missing_page_refusal`, `app/api/records.py:1593-1604`). On a dual record that does not already miss that side or both, the current image of that side, if it has one, is superseded as a retake supersedes it: the file stays on the unit and in the bucket, and the image is no longer listed in the manifest. The record then misses that side, or `both` when no current image is left. A closed record is reopened: its `closed_reason` and `closed_note` are cleared, and it is pending again. A note, stripped, is kept as `missing_note`. A record in review or approved is returned to `captured`, and the change is written to its status history, so that an operator can capture into it; a rejected record stays `rejected` (`mark_missing_page`, `records.py:1607-1646`). A record that already misses that side, or both, keeps its side and its images. The record's row and then the volume's row are locked before any status change. The response is `200` with the record; a record that does not exist is `404`. When something changed, the change is recorded in the activity log as `missing_page_marked`, with `reopened=<reason>` in the detail when a closing was cleared, and the volume may be handed over again (below) (`records.py:1649-1701`).
- **`POST /records/{id}/close-missing`.** The body is `{reason, note}`. `reason` is `foliation_skip`, `leaf_missing_from_volume`, `captured_elsewhere` or `other`. `note` is optional and at most 2,000 characters, and `other` needs one: `other` with no note, or a blank one, is refused with FastAPI's validation `422` (`CloseMissingRequest`, `app/schemas/record.py:428-438`). A record that does not exist is `404`. A record with no `missing_side` is refused with `409` and `detail` `{code: "not_missing", message}`, and a record already closed with `409` and `{code: "already_closed", message}` (`records.py:1741-1753`). The route sets `closed_reason`, and `closed_note` to the note stripped, or `null`. The record keeps its `missing_side`, stays in its volume and is no longer pending. When its volume has been handed over before, a `captured` record with no current image carrying a `rejection_id` is moved to `in_review`, as promotion would move it. A record waiting for a retake keeps its status and stays pending. In a volume never handed over, the status is left as it is, and the next promotion sends the record (`records.py:1769-1776`). No route reopens a closed record; marking its other page missing, by `POST /records/{id}/missing-page` or a Fisqua decision, reopens it, and a dual capture into it clears the closing; such a capture is accepted only while the record is `captured` or `rejected`. The response is `200` with the record. The closing is recorded in the activity log as `missing_record_closed`, with the detail `record <id> volume <id> missing_side=<side> reason=<reason>` (`records.py:1704-1787`).
- **Capturing into a missing record.** A missing record is captured into by `POST /cameras/capture/dual` with its `record_id`, as a retake. The capture supersedes any current image, writes both pages, and clears `missing_side`, `missing_expected`, `missing_note`, `closed_reason` and `closed_note`; `missing_request_id` is kept. The record keeps its sequence, and a rejected record is returned to `captured` (`app/api/cameras.py:1307-1321`). A missing record in review, approved or `excluded` is refused, like any retake of such a record, with `409` and `"Only a captured or rejected record can be retaken."` (`_refuse_retake_out_of_the_operators_hands`, `cameras.py:84-94`). `POST /cameras/capture` refuses a placeholder with `409` `placeholder_needs_dual` (A capture needs a volume with a stem, above).
- **`afterRecordId` on `POST /cameras/capture/dual`.** A dual capture that creates a record can put it right after a record of the volume: the body's `afterRecordId`, also accepted as `after_record_id` (`DualCaptureRequest`, `cameras.py:254-280`). With `record_id` as well, the request is refused with `422` and `"afterRecordId inserts a new record; it cannot be combined with record_id, which recaptures one."`, right after the resolution check (`:1085-1089`). With a `collection_id`, the volume's records and then its row are locked before the volume checks, and a volume whose records keep changing gives the renumber's `409`. After the volume and stem checks, an `afterRecordId` that matches no record is `404` with `"Record N not found"`, and a record of another volume is `422` with `"Record N is not in volume M."` (`:1096-1114`). The new record is given the sequence right after that record, and the sequences of the later records are raised by one (`:1208-1213`).
- **Promotion.** `POST /collections/{id}/promote` sends a closed missing record to review like any captured record, a closed placeholder with no image included, and leaves an open one `captured` on the unit, where the manifest lists it as `missing` (The promotion refusal, above; `_assert_promotable`, `records.py:1305-1355`).
- **Handing over again.** `POST /collections/{id}/records/missing-opening` and `POST /records/{id}/close-missing` call `hand_over_again_after_missing_change` in their own transaction every time; `POST /records/{id}/missing-page` calls it only when something changed (`records.py:1688-1690`). A Fisqua decisions set calls it when the set marked a page missing or made a placeholder. The function takes the volume's row, and queues a handover as promotion does (What a handover does, above) when the volume has been handed over before, that is, has an outbox row in any state, and now holds no `captured` record other than open missing ones and no record waiting for a retake. Otherwise nothing is queued. While Fisqua is not configured no row is added, but the volume's unsent rows still become `superseded` (`hand_over_again_after_missing_change`, `app/core/fisqua_outbox.py:689-730`; `handed_over_before`, `:680-686`; `enqueue_handover`, `:648-677`). After the commit, a route that queued a handover wakes the upload scheduler.
- **In an export.** A missing record closed without being captured that has no current image is left out of the BagIt export: it does not enter the bag, and it blocks neither the handover check nor the approval check. A closed missing record with an image is bagged once approved, like any record. An open missing record refuses the export as any other record that is not approved does: as not handed over while it is `captured`, and as not approved when it is `rejected`. A volume left with no record that holds a current image has nothing to export: `POST /collections/{id}/export` is refused with `422` and `detail` `{message: "Collection has nothing to export: no record has a current image.", blocking_record_ids: []}`, after the handover and approval checks, and the export job's own check fails the job with the same message (`_closed_without_image`, `exported_records`, `workflow_blockers`, `app/core/export_service.py:53-123`, `:153-157`; `app/api/collections.py:1366-1377`).

**An image's rotation — `rotate_deg`.** `RecordImageRead` carries `rotate_deg`, the clockwise rotation in degrees (`0`, `90`, `180` or `270`) that displays the image upright, as the capturing body was set. It is `null` for an upload and for every image captured before the column existed; nothing was backfilled, because a body's orientation can have changed since (`app/schemas/record.py:224-226`; `RecordImage.rotate_deg` and the check constraint `check_record_image_rotate_deg`, `app/models/record.py:228-231`, `:191-196`, added by migration `d7a1c3e5f9b2`). It is returned wherever the schema is: the images of a record, `GET /records/{id}/images`, `POST /records/{id}/images`, `GET /records/images/{img_id}`, `PATCH /records/images/{img_id}` and the images of a rejection (`app/api/records.py:636`, `:800`, `:820`, `:833`).

- **Where it is set.** `POST /cameras/capture` and `POST /cameras/capture/dual` write it from the capturing body's saved orientation, one value for each image of a pair (`recorded_rotation`, `capture/camera.py:83-96`; `app/api/cameras.py:1013`, `:1278`). The saved orientation is first taken modulo 360; a value that is not an integer, or that is then not `0`, `90`, `180` or `270`, is recorded as `null` (`capture/camera.py:92-96`). The capture request can override the saved orientation, `0` included: `rotate_deg` on `POST /cameras/capture`, and `rotate_deg_cam0` and `rotate_deg_cam1` on `POST /cameras/capture/dual` (`CaptureRequest` and `DualCaptureRequest`, `app/api/cameras.py:239-243`, `:260-264`; applied at `:899-900`, `:1151-1154`). A request value outside `0`, `90`, `180` and `270` is refused with the validation `422` (`:224-230`, `:248-251`, `:277-280`). Once recorded, no route changes it: `RecordImageUpdate` holds only `sequence` and `role`.
- **A RAW master is not rewritten.** The orientation is written into the EXIF Orientation tag only for a `.jpg` or `.jpeg` file, which is a JPEG master or a RAW master's `_preview.jpg`, and no tag is written for `0`. A RAW master (`RAW_SUFFIXES`, `app/core/paths.py:29-32`: `.3fr`, `.arw`, `.cr2`, `.cr3`, `.crw`, `.dcr`, `.dng`, `.erf`, `.iiq`, `.kdc`, `.mef`, `.mos`, `.mrw`, `.nef`, `.nrw`, `.orf`, `.pef`, `.raf`, `.raw`, `.rw2`, `.rwl`, `.sr2`, `.srf`, `.srw`, `.x3f`) stays as the camera wrote it, so `rotate_deg` and the `rotate_deg` of the capture record's `files` entry are where its rotation is kept (`_apply_rotation`, `capture/service.py:237-268`; `CaptureFile.rotate_deg`, `capture/manifestHandler.py:72-76`). A capture record written before the key existed lacks it.
- **Fisqua's correction.** `RecordImageRead` also carries `rotation_correction_quarter_turns`: `1`, `2` or `3` quarter-turns clockwise, or `null` when Fisqua has made none. It is set only by applying Fisqua's decisions (above, Applying Fisqua's QC decisions), is for display, and changes no file (`app/schemas/record.py:227-229`; `RecordImage.rotation_correction_quarter_turns` and the check constraint `check_record_image_rotation_correction`, `app/models/record.py:232-235`, `:197-201`, added by migration `a5f0306a8f8c`).
- **In an export.** The `metadata.json` of a BagIt export lists `rotate_deg` for each current image, and its `schema_version` is `2`, where earlier bags carry `1` or none (`METADATA_SCHEMA_VERSION`, `app/core/export_service.py:37-41`; `_metadata_payload`, `:350`). Bags already exported are not rewritten.

**Reaching the schema on a deployed appliance.** Explore the API on a development stack. On a provisioned unit, `scripts/setup-firewall.sh` allows port 8000 from the appliance's own compose network (`172.30.0.0/24`) and over `tailscale0`, but not from the venue LAN — so it is reachable for remote support, not from a laptop in the room. The proxied `/api/docs` path does not render Swagger UI, because the page requests `/openapi.json` at the site root and Nginx routes `/` to the frontend; `/api/openapi.json` does proxy correctly, so the raw schema is retrievable that way.

---


## 4. Testing the API

### 4.1 Option 1: Interactive Docs on Swagger UI

The fastest way to test endpoints is using the interactive documentation.

#### **Getting Started with Swagger UI**

1. **Open in Browser**
   ```
   http://localhost:8000/docs
   ```

2. **You'll see:**
   - All API endpoints grouped by tag (auth, users, records, projects, collections, cameras, system)
   - Green `POST`, blue `GET`, orange `PATCH`, purple `PUT`, red `DELETE` method badges

#### **Swagger UI Navigation Guide**

**Example:** To test the login endpoint:
1. Look for the **auth** section and expand it
2. Click `POST /auth/login`
3. Click **"Try it out"**, fill in credentials, click **"Execute"**
4. Copy the `access_token` from the response

**Using Bearer Tokens for Protected Endpoints**

1. Test `POST /auth/login`, copy the `access_token`
2. Click the green **"Authorize"** button (top-right)
3. Paste the token (with or without `Bearer ` prefix) and click **"Authorize"**
4. All subsequent requests automatically include your token

**Testing a Protected Endpoint Example: Create Record**

1. After authorization, find `POST /records/` under **records** section
2. Click "Try it out", fill in the request body:
   ```json
   {
     "title": "Ancient Manuscript",
     "capture_mode": "single",
     "author": "Unknown",
     "date": "1500-01-01"
   }
   ```
3. Click "Execute": view the 200 OK response with the record ID (this endpoint does not set 201; `POST /collections/` does)

##### Swagger UI Features

- **2xx (Green):** Success
- **4xx (Red):** Client error - check your request or role permissions
- **5xx (Red):** Server error - backend issue

---

### 4.2 Option 2: Complete Testing Workflow in Swagger UI

Recommended order to test the entire API:

1. **Health Check** → `GET /health` (no auth needed)
2. **Check setup state** → `GET /auth/setup/status` (no auth needed)
3. **Bootstrap, only if `needs_setup` is true** → `POST /auth/register`. This first user becomes admin. If an account already exists, skip this step: registration then requires an admin token and returns 401 without one.
4. **Login** → `POST /auth/login` (save token)
5. **Authorize** → Click Authorize button, paste token
6. **Get Current User** → `GET /users/me` (check your role)
7. **Create Project** → `POST /projects/` (admin only)
8. **Create Record** → `POST /records/`
9. **Upload Image** → `POST /records/{id}/images`
10. **Add to Project** → `POST /projects/{id}/add_record/{rec_id}`
11. **Get Record** → `GET /records/{id}`
12. **Delete Record** → `DELETE /records/{id}`

---

### 4.3 Option 3: Run Test Suite

```bash
# Run all tests with pytest
docker compose exec backend python -m pytest

# Run specific test categories
docker compose exec backend python -m pytest tests/unit/          # API, models, schemas
docker compose exec backend python -m pytest tests/integration/   # capture workflow
# Camera tests need real hardware AND the native pixi environment on the Pi;
# the dev container has no camera devices and no libcamera (Dockerfile.dev
# installs none) — see backend/DEPENDENCIES.md. On the Pi, in backend/:
#   pixi run -e dev pytest tests/test_cameras.py -m camera
# Note: the `test-cameras` pixi task is currently broken — it points at
# test/test_cameras.py, and the file is tests/test_cameras.py (NEH-195).

# Run with verbose output
docker compose exec backend python -m pytest -v

```

`pytest-cov` is not currently in either dependency manifest, so `--cov` is unavailable; `backend/pytest.ini` keeps the coverage options commented out for that reason.

**Test Organization:**
- `tests/unit/test_api.py` — API endpoint validation, imports, models, schemas
- `tests/integration/test_capture_integration.py` — Full capture workflow with database
- `tests/test_cameras.py` — Camera hardware tests (requires connected cameras)
- `tests/validate_system.py` — Complete system validation script
- `tests/conftest.py` — Shared pytest fixtures

### Option 4: Manual Testing (cURL)

```bash
# Health check
curl http://localhost:8000/health

# Register user
curl -X POST http://localhost:8000/auth/register \
  -H "Content-Type: application/json" \
  -d '{"username":"test","email":"test@example.com","password":"pass123"}'

# Login
curl -X POST http://localhost:8000/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"test","password":"pass123"}'

# Get current user's role
curl http://localhost:8000/users/me \
  -H "Authorization: Bearer <token>"
```

---

### Alternative Documentation Views

**ReDoc** (Read-only documentation):
```
http://localhost:8000/redoc
```

**OpenAPI JSON** (Raw specification):
```
http://localhost:8000/openapi.json
```

---

## 5. File Storage Architecture

### Storage Structure

Images are stored under the active projects root, `/var/lib/dtk/projects/` by default. A volume with a file name stem keeps its files in a directory named by the stem, directly under the root and outside any project. A volume without a stem keeps the name-based layout inside its project's tree:

```
<projects root>/
├── co-ahrb-aht-003/                ← a volume with a stem: <stem>/
│   ├── captures/                   ← masters (JPEG, TIFF or CR2) and uploads
│   │   ├── co-ahrb-aht-003-img_0001_c0.jpg
│   │   ├── co-ahrb-aht-003-img_0001_c1.jpg
│   │   └── ...
│   ├── previews/                   ← the _preview.jpg of each RAW master
│   ├── thumbnails/
│   └── metadata/
│       └── manifest.jsonl          ← the volume's own capture records, appended
├── project_1/                      ← a project's tree, named by project_dir_name()
│   ├── volume_b/                   ← a volume without a stem
│   │   └── images/
│   │       ├── main/               ← masters, each RAW master's _preview.jpg beside it
│   │       └── thumbnails/
│   ├── images/
│   │   ├── main/                   ← images of records attached straight to the project
│   │   └── thumbnails/
│   ├── metadata/
│   │   ├── project_manifest.jsonl  ← written at project init
│   │   └── manifest.jsonl          ← capture records made in the name-based layout
│   └── packages/                   ← created at init, currently unused
├── .retired-manifests/             ← capture manifests of deleted projects
├── .captua-offsite-staging/        ← links the offsite upload reads from; removed at each start
└── ...
```

- **The stem decides the layout.** `image_output_dir()` (`backend/capture/project_manager.py:123-139`) returns `<projects root>/<stem>/captures/` for a volume with a stem, `<project dir>/<volume dir>/images/main/` for a volume without one, and `<project dir>/images/main/` for neither. `volume_root()` (`:79-99`) refuses a value that is not a stem, so a stored stem cannot name a path outside the root. Before a capture into a volume with a stem, all four directories are created (`ensure_volume_dirs`, `:102-109`; `backend/capture/service.py:368-370`). In the name-based layout two volumes of one name share a directory, and a nested volume's directory sits beside its parent's (`collection_capture_root`, `project_manager.py:112-120`). A volume without a stem takes no capture or upload (section 3), but a move of records into it, or a rename of it or of its project, still writes files there. An upload goes to `<stem>/captures/`, named as a single capture is (see Filename Format), and its thumbnail to `<stem>/thumbnails/` (`backend/app/api/records.py:684-699`).
- **A RAW master's preview is placed by the layout.** `preview_sidecar_of()` (`backend/app/core/paths.py:75-94`) names the `_preview.jpg` of a master in `captures/` in the sibling `previews/`, and that of any other master beside it.
- **Each volume with a stem has its own manifest.** `append_manifest_record()` (`backend/capture/manifestHandler.py:323-349`) writes `project_manifest.jsonl` at project init, in the project's `metadata/`, and one `manifest.jsonl` line per capture event, carrying each file's capture-time sha256. The capture line goes to the manifest under `capture_manifest_root()` (`project_manager.py:142-151`): `<stem>/metadata/manifest.jsonl` for a volume with a stem, the project's otherwise. Its paths are relative to the directory that holds `metadata/`. Each line is appended in one `O_APPEND` write and fsynced, after a newline when the last line was torn (`_append_line`, `manifestHandler.py:302-320`). An upload into a volume writes an upload record to `<stem>/metadata/manifest.jsonl` by the same append, before its row is committed: `{record_type: "upload", capture_id, timestamp_utc, files: [{role: "single", relative_path, bytes, mimetype, sha256}]}`, with the stored file's path, size, content type and sha256 (`append_upload_record`, `manifestHandler.py:406-442`; `backend/app/api/records.py:771-778`). Its `capture_id` is the one the client sent with the upload, or a uuid4 the route gives an upload sent without one, and the image row carries the same id (`records.py:717-718`). If the commit fails, the file and thumbnail are removed and the line stays, so the number it names is not given again. When a move, or the startup migration (see Moving volumes into the stem layout at startup), renames a master with a capture id, a relocation record, `{record_type: "relocation", capture_id, image_id, sha256, from, to, relocated_at}`, is appended to the manifest of the top directory the master was moved into (`append_relocation_record`, `manifestHandler.py:370-400`; `relocation_of`, `backend/app/core/storage_ops.py:56-83`; `_record_relocation`, `backend/app/core/volume_layout.py:990-1015`). A renumber renames no file and writes no relocation record. With no capture-time checksum to carry, no record is written and a WARNING is logged. A project's manifest is not deleted with the project: `DELETE /projects/{id}` moves it to `.retired-manifests/<project dir>-<UTC timestamp>-manifest.jsonl` first, and refuses with `409` a tree that holds any other capture manifest (`backend/app/api/projects.py:417-431`, `retire_project_manifest`, `storage_ops.py:639-670`).
- **Old and new manifests are read together.** `build_fixity_index()` (`backend/app/core/integrity.py:131-277`) reads every `metadata/manifest.jsonl` under the projects root, each project's and each volume's, and the retired ones (`_manifests`, `:299-310`). Paths in a manifest are resolved against the directory that holds its `metadata/`, or, for a retired one, against the project directory its file name carries (`manifest_base`, `:313-325`). A capture record gives each file's sha256 by path and by file name, and an upload record is read as a capture record (`:137-139`); a relocation record that names its image gives that image's sha256 directly. A line that is not JSON is skipped, and the count is logged. The export fixity gate (`_fixity_gate`, `backend/app/core/export_service.py:298-324`) refuses the bag with `checksum_mismatch` when a file's bytes differ from its sha256, and with `checksum_unresolved` when an image's capture id has a capture record in some manifest but no sha256 resolves for the image; an image whose capture id has no capture record anywhere, such as an upload made before uploads were written to the manifest, passes unchecked, and a later upload is checked against its upload record (`verify_images_against_manifest`, `integrity.py:384-432`). The bag's `data/metadata/manifest.jsonl` holds the capture records of the volume's current images from every manifest, without relocation or `preview_digest` records; where both a capture-time record and a migration copy exist, the capture-time record is used. The upload records of the volume's current images are included as capture records are (`capture_record_lines`, `integrity.py:328-375`, with uploads at `:337-338`, `:361-362`; `export_service.py:260-262`, `:388-404`; `backend/app/core/bag_export.py:90`).
- **Renames and moves no longer touch migrated files.** No file in `<stem>/` is moved when the volume is renamed, re-parented or moved to another project, and when its project is renamed. Files still in the name-based layout, which are every file of a volume without a stem and those of a volume given a stem since the last start, are moved as before, and the operation is refused with `409` while an export of a volume with such files is queued or running (`collections_in_old_layout`, `storage_ops.py:179-202`; `backend/app/api/collections.py:645-653`; `projects.py:211-213`, `:326`, `:329`). `POST /collections/{id}/move-records` still moves the records' files, to the target's `<stem>/captures/` or to its name-based directory (`collection_image_dir`, `storage_ops.py:232-244`; `collections.py:750`). A record with an image in the offsite bucket is not moved out of its volume at all, by this route, by `PATCH /records/{id}` or by `POST /projects/{id}/add_record/{rec_id}` (section 3). `DELETE /collections/{id}` removes only the volume's empty directories; a file found there that no row references stays where it is and is logged (`remove_empty_dirs`, `storage_ops.py:679-696`; `collections.py:880-889`).
- **`packages/` is not where exports go.** It is created at project init and nothing writes into it. BagIt exports are written to `settings.exports_dir`, `/var/lib/dtk/exports` by default (`backend/app/core/config.py:255-257`, `backend/app/core/export_service.py:167`).
- **There is no `temp/` or `trash/` directory under the projects root, and deletion is permanent.** Deleting a record unlinks its files, as does deleting a single image (`delete_record` and the image delete handler in `backend/app/api/records.py`); each takes the master, the thumbnail and the `_preview.jpg` sidecar where `preview_sidecar_of()` places it. There is no recovery directory, and on a backup-less appliance a delete is final. An object already uploaded stays in the offsite bucket: its `offsite_objects` row is kept. On PostgreSQL the foreign key sets its `record_image_id` to null; on SQLite, where the backend does not turn foreign keys on, the id is left pointing at no image (`backend/app/models/offsite_object.py:8-10`, `:53`; `backend/app/models/collection.py:95-96`).
- **The root is not fixed.** Activating an external storage device changes `settings.projects_dir` at runtime, so captures may live somewhere other than the default microSD path.

### Moving volumes into the stem layout at startup

Volumes captured before stems existed, and volumes given a stem later, have files in the name-based layout. At every start, after the project rename reconciliation, the backend runs `migrate_volume_layout_at_startup()` (`backend/app/main.py:46-52`; `backend/app/core/volume_layout.py:1730-1753`), and the migration moves the existing files of each volume with a stem into `<stem>/`. New captures and uploads into a volume with a stem are written to `<stem>/captures/` at once.

- **The rows decide what is moved.** An image row of a volume with a stem is out of place when its stored path is under the active projects root and not in the volume's `captures/` (`_expected_dirs` and `_out_of_place`, `volume_layout.py:282-318`). Nothing else is looked at: finding the rows takes one query for the stems, one over the image rows and a string comparison per row, with no filesystem access per row. The files of a volume without a stem are left where they are. Files are attributed by their rows, never by the directory they are in, so the migration separates two volumes of one name that share a directory.
- **What is moved, and where.** The migration moves a master to `captures/`, a RAW master's sidecar to `previews/` and a thumbnail to `thumbnails/`, and keeps their names. No file is moved onto an existing one. A master's name counts as taken when a file in `captures/` has it (compared case-folded), when its sidecar's name is taken in `previews/`, or when a file of another record in `captures/` has the same stem (`_Dir.master_taken`, `:347-353`). A master whose name is taken is renamed by inserting `_img<image id>` before its suffix, then `_img<image id>_2`, `_3` and on, so `20260109_143652_123_c0.jpg` of image 42 becomes `20260109_143652_123_c0_img42.jpg` (`_suffixed_stems`, `:380-387`; `:801-807`; `_free_name`, `:929-953`). A renamed master with a capture id gets a relocation record in the volume's manifest before it is moved (`_record_relocation`, `:990-1015`). The migration moves only files under the active projects root, so uploads made before this layout, under `<DTK_DATA_DIR>/uploads/`, stay there and are skipped as `outside_projects_root` (`:703-705`).
- **A row whose file is already in place.** When a row's old path is gone, a file in the volume's `captures/` under the row's own name or one of the clash names, and that no row references, is adopted: the row is pointed at it, but only when its sha256 matches the capture-time checksum held for the image. Adopted rows are listed under `adopted`. With no matching checksum the image is skipped as `missing` (`_adoptable`, `:440-470`; `:770-791`). A row whose master was freed from the card is never `missing`: no file moves for it, its row is pointed at the name the master would have been moved to, and it is listed under `freed_paths_moved`; that name, and a freed preview's, stays taken for later moves (`volume_layout.py:62-69`).
- **Thumbnails.** A thumbnail whose name is taken in `thumbnails/`, or whose file is missing, has its row cleared, and the image is listed under `thumbnails_cleared` with the reason `name_taken` or `missing`; the thumbnail route regenerates it (`:833-845`, `:1159-1179`). A thumbnail that cannot be moved keeps its row and is listed under `thumbnails_not_moved`.
- **The volume's records are copied first.** Before the migration moves a volume's files, it copies the volume's capture records and their relocation records from every other manifest into `<stem>/metadata/manifest.jsonl`, marked `copied_from` and with their paths rebased onto `<stem>/`. The manifests they are copied from are not changed (`_copy_volume_records`, `:1302-1324`).
- **The journal.** The work is done one volume at a time. The migration writes the volume's planned moves to `<DTK_DATA_DIR>/volume-layout.journal` before it moves any file; after the moves it fsyncs the directories, commits the rows and removes the journal (`:1517-1524`; `_commit_batch`, `:1327-1339`). At startup the migration completes a journal it finds before anything else (`:1475-1490`).
- **When the backend does not serve.** Any `VolumeLayoutError` is re-raised and the backend does not serve: a pending journal that names another projects root, a journal or sidecar list that cannot be read (`:1478-1482`; `_read_json`, `:179-185`), or a volume manifest that cannot be read while records are copied (`:1254`). Another failure that leaves a journal is re-raised too. Any other failure is logged and the backend serves, as it does when the projects root cannot take writes (`:1740-1752`).
- **What is skipped or fails.** Each image the plan does not move is listed under `skipped` with a `reason`. A volume whose `<stem>/` already holds entries that are not the volume's is not moved; each of its images has the reason `stem_dir_occupied` and the list `foreign` (`_foreign_entries`, `:549-639`). A volume whose `<stem>/` is a live project tree has the reason `stem_dir_is_project_tree`. A stored stem that is not a valid stem gives `no_stem` (`:727-729`, `:737-739`). Single images can also be skipped as `outside_storage`, `outside_projects_root`, `missing` or `row_changed` (`:700-705`, `:777-779`, `:1048-1050`). An image whose move fails is listed under `failed` with `image_id`, `path` and `error`; its file and row are left as they were, and the migration goes on with the next image (`:1111`, `:1125`). A sidecar that cannot be moved with its master is listed under `sidecars_not_moved`, recorded in `<DTK_DATA_DIR>/volume-layout.sidecars`, retried at every start, and listed under `sidecars_pending` until it has been moved (`:1157`; `_retry_sidecars`, `:1342-1421`).
- **What else is reported.** A writer's temporary file in `<stem>/` is not counted as foreign; it is left where it is and listed under `temp_files_left`. A generated thumbnail (`<uuid4 hex>_thumb.jpg`) that no row owns is treated the same way and listed under `orphan_thumbnails_left`. On a run that finds out-of-place rows, the files no row references in the name-based volume directories, and in the directories files are moved out of, are listed under `left_unreferenced` and stay where they are (`_unreferenced_in_collection_dirs`, `:871-903`; `:849`, `:1506`). So is a file that no row references and that took a name a master was denied, forcing the clash rename, in `captures/` or, for a RAW master, `previews/` (`_clashing_files`, `:356-377`; `:808-813`), and a file that took a master's planned name after planning (`:1082-1097`). Such a file makes the volume's `<stem>/` hold what is not the volume's, so a later run that has more of the volume's files to move skips it as `stem_dir_occupied` until the file is removed. At every start each volume's leftover `metadata/manifest.jsonl.part`, written by an earlier version of the manifest copy, is removed and counted in `stale_parts_removed`; one that cannot be removed is counted too, and logged at ERROR (`_remove_stale_parts`, `:1530-1553`). After the moves, each migrated volume's own manifest is checked for a capture record per capture id of its images. The missing ones are copied in from the other manifests and counted per volume in `manifests_repaired`, and capture ids that no manifest holds are listed per volume in `captures_without_record` (`_repair_volume_manifests`, `:1556-1672`). The capture ids found in no manifest are kept in `<DTK_DATA_DIR>/volume-layout.missing-records` with each manifest's path, size and modification time, and the search of every manifest is skipped while both the missing ids and the manifests are unchanged (`:1631-1641`). The report's keys are set in `_new_report` (`:1424-1450`). At startup the findings are logged. `python -m app.core.volume_layout [--dry-run]`, run with the backend stopped, prints the report as JSON and exits with 1 when `failed` is not empty; a dry run writes nothing and lists a pending journal's entries under `pending_journal_entries` without completing it (`main`, `:1756-1780`; `:1483-1486`).

### Offsite copies

The backend puts two kinds of object in the offsite destination, `DTK_OFFSITE_REMOTE`, both under the tenant prefix `DTK_OFFSITE_TENANT`: each image of a volume with a stem, and an encrypted dump of the catalogue database. At boot, and only when the remote and a valid tenant are set, the backend starts an in-process schedule for each, which first runs `DTK_OFFSITE_BACKUP_DELAY` seconds after the start and then `DTK_OFFSITE_BACKUP_INTERVAL` seconds after each run ends (`backend/app/main.py:61-70`; `ImageUploadScheduler`, `backend/app/core/image_upload.py:1553-1648`, its loop at `:1618-1624`; `catalogue_backup.py:903-909`). Both copy with rclone under one lock, so one object is in transit at a time within the one `DTK_OFFSITE_BWLIMIT` cap, and both pass `--no-check-dest`, because the appliance's key can write and list but not read (`upload_file`, `image_upload.py:353-377`; `transfer_lock`, `backend/app/core/catalogue_backup.py:112`).

```
<DTK_OFFSITE_REMOTE>/
└── <tenant>/                                  ← DTK_OFFSITE_TENANT
    ├── <stem>/                                ← one per volume with a stem
    │   ├── captures/<name>                    ← each image as shot, current and superseded
    │   └── previews/<name>                    ← each RAW master's _preview.jpg
    └── db-backups/                            ← DTK_OFFSITE_DB_PREFIX
        └── catalogue-<YYYYMMDD-HHMMSS>-<hex>.sql.gz.age
```

- **What is uploaded.** Every image of a volume with a stem, current and superseded alike, and the preview of each RAW master whose preview file exists. Thumbnails are never uploaded, and the images of a volume without a stem are not uploaded (`image_upload.py:1-17`). Finding work does not scan the disk: one query selects the images of volumes with a stem that have no verified or refused row for their capture or, for a RAW master, for their preview (`pending_work`, `:401-435`). A capture is not held up by the upload: the worker holds no database lock and no transaction while rclone runs, and a file whose size or modification time changes while it is hashed is skipped for that run (`:42-46`; `stable_digests`, `:329-344`).
- **Keys are frozen at first upload.** `<name>` is the file's name on disk when the unit first uploads the object (`capture_key` and `preview_key`, `image_upload.py:174-179`; `:721-726`). The key is stored in `offsite_objects.object_key` and never changed: every later run uses the stored key, and a `before_update` guard raises `ImmutableFieldError` on any change to it (`backend/app/models/offsite_object.py:78-86`). The guard is an ORM listener, so it applies to changes made through the ORM and not to raw SQL or a bulk `query().update()`. A downgrade below migration `b8d2f4a6c1e3` drops the table, and with it every recorded key (`backend/alembic/versions/b8d2f4a6c1e3_add_offsite_objects.py:62-65`). A move on disk or a project rename leaves the bucket as it is (`image_upload.py:14-17`). When a new object's key is already another image's key, the object is keyed beside it with `_img<image id>` before the suffix (`disambiguated_key`, `image_upload.py:182-186`; `:728-738`). A key that another row holds even then is reported under `conflicts` and nothing is uploaded (`image_upload.py:739-744`).
- **Keys are reserved before the transfer.** The object's row is committed with its key, as a pending row, before rclone starts. A record move requested during the copy is then refused (section 3), and a crash after the copy leaves the key frozen for the next run to verify (`image_upload.py:778-782`; `_claim`, `:641-666`). A pending row is never deleted. On a later run the uploader lists the key and verifies the object there, copies it again to the same key, or refuses or skips it on the checks above and below (`offsite_object.py:21-26`; `image_upload.py:746-776`). A pending row whose image was deleted, so that its `record_image_id` is null, is never selected again: the work list is built from the image rows (`pending_work`, `image_upload.py:413-418`).
- **Nothing is overwritten.** Before each upload the key's directory is listed. An object already at the key with the local SHA1 is recorded as verified without an upload; one with another SHA1 is refused as `remote_differs` and not retried; an entry with no SHA1 is skipped (`image_upload.py:761-776`). The copy itself is `rclone copyto`, and the listing before it is what keeps it from overwriting (`image_upload.py:353-364`). The listing and the copy are two steps, so this holds against what the listing showed. A capture is also checked against its capture-time sha256 before it is uploaded, and refused as `fixity` on a mismatch that persists when the manifests are read again (`image_upload.py:746-756`).
- **Objects are verified by listing.** An object counts as verified only when a listing shows its key with the local SHA1: the listing before an upload, for an object already there; the listing after it; or the adoption listing (`image_upload.py:768-771`, `:786-790`; `:986-987`). A copy command that succeeded sets `uploaded_at`, and the object stays pending until a listing confirms it (`image_upload.py:784-803`). rclone's B2 backend uploads a file above `--b2-upload-cutoff` (200 MiB by default) in parts, and the listing's SHA1 for such a file comes from its `large_file_sha1` metadata. rclone sets that from a local source, but a part-uploaded object without it lists no SHA1, and without a SHA1 nothing is verified (`image_upload.py:792-798`). When a listing does not answer, the uploader stops the run with the status `aborted`, and when a copy fails, with `failed`. rclone's "directory not found" is read as absence only when the parent directory's listing answers and does not show the directory, or for the tenant prefix itself, and nothing above `<remote>/<tenant>/` is listed (`_entries`, `image_upload.py:204-235`; `run_image_upload`, `:806-884`).
- **The bytes come from a staged link.** The file is read through a hard link in `<projects root>/.captua-offsite-staging/`, made under the files-being-read hold (section 3), so a move that renames the file during the upload cannot change the bytes that are sent. Where the file system cannot make a hard link, a copy is made there instead and removed after the upload. The directory is removed at each start, and the integrity check does not count its files (`_stage`, `image_upload.py:300-326`; `sweep_staging`, `:274-281`; `OFFSITE_STAGING_DIR`, `backend/app/core/paths.py:47-50`; `backend/app/core/integrity.py:67-68`).
- **`offsite_objects`.** Created by migration `b8d2f4a6c1e3` (`backend/alembic/versions/b8d2f4a6c1e3_add_offsite_objects.py`). One row per object: `record_image_id` (a foreign key to `record_images.id`, `ON DELETE SET NULL`), `kind` (`capture` or `preview`), `object_key` (unique across all rows, relative to `DTK_OFFSITE_REMOTE`), `local_sha1`, `remote_sha1`, `uploaded_at`, `verified_at`, `refused_at`, `refusal` and `created_at`; an image has at most one row of each kind (`offsite_object.py:49-75`). The states are derived from the columns, and a check constraint keeps `verified_at` and `refused_at` from both being set (`:12-29`, `:70`): **verified**, `verified_at` set; **refused**, `refused_at` and `refusal` set; **pending**, neither, with no `uploaded_at` while the key is only reserved, and with it once the copy command has succeeded. An adopted object has `verified_at` and no `uploaded_at`. When an image row is deleted, its rows stay as the unit's record of what it put in the bucket. On PostgreSQL `record_image_id` is set to null; on SQLite, without foreign keys, it is left pointing at no image (`:8-10`, `:53`; `backend/app/models/collection.py:95-96`).
- **The system log.** After each run that did any work, the uploader writes `image_upload_run` to the system log, in the `system` category, at `INFO` when it finished or was stopped with no refusal and at `WARN` otherwise. Its subject is the status and its detail the counts `uploaded`, `already_present`, `unverified`, `refused`, `conflicts` and `skipped`, with the error when there was one (`image_upload.py:100-103`, `:872-883`). Each refusal is logged as `image_upload_refused` (section 3).
- **Adopting objects already in a bucket.** `python -m app.core.image_upload adopt <prefix> [--apply]` lists `<prefix>`, relative to `DTK_OFFSITE_REMOTE`, recursively. It hashes each object of a volume with a stem that has no row yet, and when exactly one listed object carries the same SHA1, records that object's key as the image's frozen key, verified, with no upload. Two or more listed objects with the SHA1 (`ambiguous_remote`), two local objects matching one listed object (`ambiguous_local`) and a key another row already holds (`key_already_held`) are reported, and nothing is recorded for them. With `--apply`, an image whose record moved or whose file changed after it was hashed is reported under `changed` and not adopted; `changed` is filled only then. A file or image row that changes around the hash itself is reported under `unreadable`. Without `--apply` nothing is written. The command neither requires nor applies `DTK_OFFSITE_TENANT`: `<prefix>` is any prefix under the remote. The command prints the report as JSON, with the keys `prefix`, `listed`, `listed_without_sha1`, `adopted`, `ambiguous_remote`, `ambiguous_local`, `key_already_held`, `changed`, `unmatched` (a count), `unreadable` and `applied`, and exits with `0`; with an empty prefix, no remote configured or a listing that does not answer, it prints `error: <reason>` and exits with `2`. With `--apply` it writes `image_upload_adopted` to the system log with the counts (`adopt_objects`, `image_upload.py:891-1004`; `main`, `:1658-1735`). It runs in a process of its own, outside the backend's read hold, so it checks instead that the file's inode and the image's row are the same before and after the hash (`:939-956`). An adopted key is whatever was found under the operator's prefix: its name may differ from the file's name on disk, and it may sit under another stem than the volume's (`:9-14`).
- **Adopting from a rename map.** `python -m app.core.image_upload adopt-map <map.json> [--apply]` reads a contract 1.1 rename map, which lists for one volume the key each capture and preview was copied to in the destination bucket, and records each listed object as the frozen key of its image, verified, with no upload (`adopt_rename_map`, `image_upload.py:1120-1318`; `load_rename_map`, `:1321-1329`; the command, `:1671-1678`, `:1725-1726`). Unlike `adopt`, it records keys for images whose files are absent from the card, so `mark-freed` can then mark those files as freed (`:1125-1126`).
  - **Whole-map refusals.** The command prints `error: <reason>`, lists nothing, writes nothing and exits with `2` when the file cannot be read or is not JSON; when the map is not a JSON object, or its `contract`, `version` or `kind` is not `fisqua-captua-exchange`, `1.1` and `rename-map`; when it has no `volume` or `destination` object, or `entries` is not a list; when no volume on the unit has both the map's `volume.captuaCollectionId` and `volume.stem`; when `DTK_OFFSITE_REMOTE` is unset or is not of the form `<remote>:<bucket>`, or its bucket is not the map's `destination.bucket`; when `destination.root` is not a key prefix; when `DTK_OFFSITE_TENANT` is unset or invalid; and when the root's first segment is not that tenant (`_read_rename_map_header`, `image_upload.py:1068-1117`; `_remote_bucket`, `:1018-1037`; `:1321-1329`; `:1729-1731`). A listing that does not answer also ends the command with `2` (`:1246`).
  - **Per-entry checks.** Each entry is recorded at `<destination.root>/<destinationKey>`, the root stripped of surrounding whitespace and slashes (`image_upload.py:1098-1102`), only when every check passes. Otherwise it is listed under `refused` with its `index`, `image_id`, `kind`, `key` and `reason`, and, for most reasons, the values that differed. The reasons are: `malformed_entry` (an entry that is not an object; a missing or mistyped `imageId`, `recordId`, `originalFilename` or `sha1`; a `kind` other than `capture` or `preview`; a `sha1` that is not 40 hexadecimal digits; an empty `originalFilename`; or a mistyped `bytes` or `captureId`); `key_outside_volume` (the key is not `<tenant>/<stem>/captures/<name>` for a capture or `<tenant>/<stem>/previews/<name>` for a preview, or `destinationKey` is not a plain relative path); `duplicate_entry` (among the entries that passed the shape and key checks, more than one names the same image and kind, or the same key; every such entry is refused); `image_not_found`; `record_differs`; `not_in_volume`; `capture_differs` (when the entry gives a `captureId`); `filename_differs` (`originalFilename` is not the master's name for a capture, or its preview's for a preview); `key_differs` (the image already has a row of that kind at another key); `key_already_held` (another row holds the key); `not_in_bucket`, `listed_without_sha1` and `bucket_sha1_differs` (from a fresh listing of the key's directory); `bucket_size_differs` (when the listing and the entry both give a size); `unreadable` and `local_sha1_differs` (when the file is on the card, it is hashed and must carry the entry's `sha1`); and, with `--apply`, `changed` (the image moved or its row changed after it was checked) and `recorded_meanwhile` (`_map_entry_fields`, `image_upload.py:1049-1065`; `_map_key`, `:1040-1046`; `:1181-1303`). An image that already has a row at the same key is listed under `already_recorded`, with `verified`, and not counted as refused (`:1232-1238`).
  - **The report.** `{map_id, filename_stem, collection_id, key_prefix, entries, applied, adopted, adopted_present, adopted_absent, already_recorded, refused, refused_counts}`. Each adopted entry carries `index`, `image_id`, `kind`, `key`, `sha1`, `bytes`, `local` (`present` or `absent`) and `local_path`; `refused` is sorted by `index`, and `refused_counts` counts the reasons (`image_upload.py:1168-1171`, `:1289-1309`). Rows are written through `_claim`, as `adopt` writes them. Without `--apply` nothing is written; with it, `image_upload_adopted` is logged in the system log with the volume's stem as subject, at `WARN` when any entry was refused and at `INFO` otherwise, with the detail `rename-map <map id>: adopted=<n> absent=<n> present=<n> already_recorded=<n> refused=<n>` followed, when any entry was refused, by the reason counts in parentheses, sorted by reason, as `(<reason>=<n> ...)`; the detail is cut at 500 characters (`:1292-1302`, `:1311-1317`; `_log`, `:489-490`).
- **Raising a volume's capture counter.** `python -m app.core.image_upload raise-capture-counter <stem> <n> [--apply]` raises the `capture_counter` of the volume with that stem to `n`, so the next number a capture tries is `n + 1`. It is for numbers given outside this unit, such as the `counterAfter` of a rename map whose copies exist only in the bucket (`raise_capture_counter`, `app/core/capture_counter.py:63-110`; the command, `image_upload.py:1694-1702`, `:1721-1724`). The volume's row is taken under the same lock a capture takes before it raises the counter, and the value is read again under it (`capture_counter.py:91-96`). It refuses, with `error: <reason>` and exit code `2`, an `n` outside 0 to 9999, a stem no volume has, and an `n` below the current counter, which never decreases (`:87-100`; `image_upload.py:1729-1731`). The report is `{stem, collection_id, counter_before, counter_after, raised, applied}`. Without `--apply`, nothing is written. With `--apply` and an `n` equal to the counter, nothing is written and the report's `applied` is `true`. With `--apply` and a higher `n`, the raise is committed and logged in the system log as `capture_counter_raised`, with the stem as subject and the detail `collection_id=<id> from=<before> to=<n>` (`capture_counter.py:101-110`).
- **Preview digests.** A capture record lists a RAW master's `_preview.jpg` beside the master, as an entry with the role `<role>_preview` (`single_preview`, `left_preview`, `right_preview`), its `relative_path`, `bytes`, `mimetype: "image/jpeg"` and `sha256`, when the sidecar exists at the time the record is written (`_preview_file`, `backend/capture/manifestHandler.py:141-165`; `:257-259`, `:272-274`). For previews captured before that, `python -m app.core.image_upload backfill-preview-digests <stem> [--apply]` computes each one's sha256 from the file on disk and appends a `preview_digest` record to the volume's `metadata/manifest.jsonl`: `{record_type: "preview_digest", capture_id, image_id, files: [{role: "<role>_preview", relative_path, bytes, mimetype, sha256}], computed_at, backfilled: true}`. Existing lines are never rewritten (`backend/app/core/preview_digests.py:1-18`, `:163-173`). Where the preview has an offsite row, its file is backfilled only while its SHA1 is still the row's `local_sha1`; otherwise it is reported under `sha1_differs`. The report also lists `already_recorded` (a count), `no_capture_id`, `freed`, `missing`, `outside_volume`, `unreadable` and `changed`, and every image of the volume with a RAW master is considered, current or superseded (`:20-37`, `:100-102`, `:157-161`). Without `--apply` nothing is written; with it, `preview_digests_backfilled` is logged in the system log (`:178-185`). A stem no volume has prints `error: ...` and exits with `2` (`:82-85`; `image_upload.py:1729-1731`). The fixity index reads both kinds of entry, so freeing, the backfill and the capture manifest export find a preview's digest in either (`build_fixity_index`, `backend/app/core/integrity.py:158-175`). A `preview_digest` record is not a capture record, and the export bag leaves it out with the relocation records (`integrity.py:338-340`; `is_capture_record`, `manifestHandler.py:365-367`).
- **Files removed by hand.** `python -m app.core.image_upload mark-freed <stem> [--apply]` records as freed each file of the volume that is absent from the card when its verified object is listed, in a fresh listing, with the row's SHA1. It deletes nothing, and records the size the listing gives. An absent file the bucket does not account for is reported under `unaccounted`, with the reason `no_verified_object`, `not_in_bucket`, `listed_without_sha1` or `bucket_sha1_differs`; with `--apply`, a file that came back is reported as `file_reappeared` and a changed row as `changed`. The report is `{filename_stem, collection_id, applied, marked, unaccounted, marked_bytes, manifest}`. With `--apply` it writes an `offsite-freed-<UTC>.jsonl` run manifest only when it marked something, and logs `volume_freed` with a detail that begins `mark-freed:` only when it marked or left unaccounted anything (`mark_freed`, `backend/app/core/offsite_free.py:1068-1155`, the log at `:1151-1154`; `_RunManifest`, `:495-532`; `image_upload.py:1679-1686`, `:1713-1716`).
- **The catalogue dump.** The scheduler runs a dump at each tick until one has been verified on the appliance's local day, and then none until the next day (`needs_run_today`, `catalogue_backup.py:661-678`). In each run the backend dumps the catalogue through gzip to a temporary file under `<DTK_DATA_DIR>/tmp/`, encrypts it with age to the X25519 public key in `DTK_OFFSITE_DUMP_RECIPIENT`, removes the plaintext, uploads the ciphertext to `<remote>/<tenant>/<DTK_OFFSITE_DB_PREFIX>/`, checks its SHA1 against the listing, and records `catalogue_backup_verified` in the system log (`:9-29`; `remote_dir`, `:257-266`; `run_catalogue_backup`, `:695-830`). No plaintext dump is uploaded. With no recipient, or a value that is not an `age1...` public key (a private key, `AGE-SECRET-KEY-...`, included), no dump is written (`dump_recipient`, `:131-153`), and `upload` refuses any file whose name does not end in `.age` or whose first bytes are not the age header (`:482-497`). The unit is given only the public key; a private key in the setting is refused. Each dump's name carries the UTC time to the second and a 24-bit random token, so a retry adds an object rather than writing over one (`_object_name`, `:284-295`). An empty tenant disables the dump, as an empty remote does. What `GET /system/catalogue-backup` reports is in section 3.

### Filename Format

New captures and uploads are named under exchange contract 1.1, section 3:

`<stem>-img_<nnnn>_c<n>.<ext>`

- `<stem>` — the volume's `filename_stem`
- `<nnnn>` — the volume's capture number, zero-padded to four digits, from `0001` to `9999`. `take_filename_index` refuses a number above 9999 (`backend/app/core/capture_naming.py:239-242`; `MAX_CAPTURE_NUMBER`, `:37`), and `capture_filename_index` formats the number it is given (`:64-70`)
- `c<n>` — the camera index (`c0`, `c1`); an upload is always `c0`
- `.<ext>` — the file's suffix

**Example**: `co-ahrb-aht-003-img_0001_c0.jpg` and `co-ahrb-aht-003-img_0001_c1.jpg`, the two images of one dual capture.

`<stem>-img_<nnnn>` is the capture event's filename index. Both images of a dual capture carry it, and it is their pair id; a single capture has no pair id (`backend/capture/service.py:426`, `:709`). A stem holds at most 27 characters and the number at most four digits, so the index always fits the 36-character `pair_id` column (`backend/app/models/record.py:174`; `backend/app/models/collection.py:11-19`). A RAW master's preview is `<stem>-img_<nnnn>_c<n>_preview.jpg`, in the volume's `previews/` (`preview_sidecar_of`). An upload is named `<stem>-img_<nnnn>_c0` with the client's suffix, lowercased, when it is `.jpg`, `.jpeg`, `.png`, `.tif`, `.tiff` or `.webp`, and otherwise the suffix of its content type; the name the client sent is logged at INFO with the name the file is stored under, and not kept (`_upload_suffix`, `backend/app/api/records.py:629-633`, `:710-712`).

`take_filename_index` (`capture_naming.py:205-247`) takes one number per capture event or upload, in the transaction that writes the event's images. It passes over a number that a file in the volume's `captures/` or `previews/` already carries, under any suffix and compared case-folded (`capture_name_taken` and `files_carrying`, `:73-117`), or whose `<stem>-img_<nnnn>_c` the volume's `metadata/manifest.jsonl` holds anywhere in its text, in capture, upload and relocation records alike (`manifest_capture_numbers`, `:142-177`, the match at `:148-154`), or that an `offsite_objects` key under the volume's stem carries. A key carries a number when its second path segment is exactly the stem and its file name starts with `<stem>-img_<digits>_`, compared without regard to case (`offsite_capture_numbers`, `:180-202`, the checks at `:192`, `:197`; `:234`, `:244`), whatever its first segment: the configured tenant, an earlier tenant, or a prefix recorded by `adopt`. `adopt-map` records keys only under the configured tenant (`image_upload.py:1109-1116`, `:1191`). Numbers carried by offsite keys count towards the 100 passed over before the capture is refused, and the refusal's text is the same (`capture_naming.py:39-42`, `:48-50`, `:247`). Numbers can be skipped; none is given twice. The refusals are listed in section 3. `capture_image` also refuses a name that a file took after the number was chosen (`service.py:383-384`); that `FileExistsError` reaches the client as `200` with `{success: false, error}`, and the transaction is rolled back (`backend/app/api/cameras.py:1057-1061`, `:1340-1344`).

Files written before this naming keep their names. Earlier captures are named `YYYYMMDD_HHMMSS_mmm_cX.jpg` (UTC date, time, milliseconds and camera index, for example `20260109_143652_123_c0.jpg`), and earlier uploads `<uuid hex><suffix>`. The startup migration keeps every name except on a clash, when it inserts `_img<image id>` before the suffix (`20260109_143652_123_c0_img42.jpg`).

### Data Flow Architecture

```
┌─────────────────┐
│  API Client     │  (Frontend / cURL / Python)
└────────┬────────┘
         │ POST /cameras/capture
         ▼
┌──────────────────────┐
│  FastAPI Endpoint    │  cameras.py
│  - Validates request │
│  - Checks auth/role  │
└────────┬─────────────┘
         ▼
┌──────────────────────────────────┐
│  Capture Service                 │  capture/service.py
│  - Loads calibration from        │  - Uses picamera2/libcamera
│    camera registry               │  - Applies camera settings
│  - Captures image to:            │
│    /var/lib/dtk/projects/<stem>/ │
│    captures/                     │
└────────┬─────────────────────────┘
         ▼
┌──────────────────────────────────┐
│  Metadata Extraction             │  PIL / EXIF
│  - Image dimensions              │
│  - EXIF data (datetime, GPS)     │
│  - Camera settings used          │
└────────┬─────────────────────────┘
         ▼
┌──────────────────────────────────┐
│  Create Database Records         │  SQLAlchemy ORM
│  - RecordImage (main record)     │
│  - CameraSettings (capture cfg)  │
│  - ExifData (image metadata)     │
└────────┬─────────────────────────┘
         ▼
┌──────────────────────────────────┐
│  PostgreSQL Database             │
│  - Image metadata stored         │
│  - Linked to project + record    │
└──────────────────────────────────┘
```

### Database Relationships

```
Record (title, capture_mode, project_id, collection_id)
    └─> RecordImage[] (file_path, filename, format, role)
            ├─> CameraSettings (camera_model, white_balance, lens_model)
            └─> ExifData (raw_exif, datetime_original, GPS)

Project (name, description)
    └─> Record[]
    └─> Collection[]
            └─> Collection[] (nested sub-collections)
```

### Performance Metrics

Measured on a Pi 5 during hardware validation, 23–24 July 2026. The picamera2
figures are at the medium preset; the presets do not apply to gphoto2, which
shot at whatever the camera bodies were set to (see the storage note below).
Earlier figures in this section were estimates, and were roughly double the
real throughput and six to eight times the real file sizes.

**Dual capture, seconds per pair:**

| Backend | Measured | Note |
|---|---|---|
| gphoto2 (Canon EOS 1500D ×2) | ~4 s | |
| picamera2 (IMX519 ×2) | 7–8 s | too slow for production; NEH-173 tracks the fix |

Both already fire the two cameras in parallel (ThreadPool with a 20 ms stagger,
`capture/service.py:661`), and both backends lock per camera index rather
than globally, so the cost is per-capture work and not serialisation.

**Throughput** follows from the above: roughly 900 pages/hour on picamera2 and
1800 on gphoto2, at two pages per capture. Treat these as ceilings — they
exclude page turning, which dominates in practice.

**Storage, picamera2 only:** at the medium preset, paired JPEGs measured
**560–780 KB each**, so 100 pages is roughly 56–78 MB.

This figure does not transfer to gphoto2. No file sizes were measured on the
DSLR path, and the resolution presets do not apply to it at all — most
`CameraConfig` fields are picamera2-specific and are silently ignored by the
gphoto2 backend (`capture/backends/gphoto2_backend.py`, `capture_image()`), which shoots
at whatever the body is set to. Sizing storage for a DSLR unit from the number
above will under-provision badly. The low and high picamera2 presets are also
unmeasured.

---

## 6. Code Examples

### Complete Workflow: Registration to Gallery

```python
import requests

BASE_URL = "http://localhost:8000"

# 1. Register first user (becomes admin)
print("1. Registering user...")
user_resp = requests.post(
    f"{BASE_URL}/auth/register",
    json={
        "username": "john_doe",
        "email": "john@example.com",
        "password": "secure_password_123"
    }
)
user = user_resp.json()
print(f"   Registered: {user['username']} (role: {user['role']})")

# 2. Login
print("\n2. Logging in...")
login_resp = requests.post(
    f"{BASE_URL}/auth/login",
    json={"username": "john_doe", "password": "secure_password_123"}
)
token = login_resp.json()["access_token"]
headers = {"Authorization": f"Bearer {token}"}

# 3. Get current user role (frontend uses this for dashboard routing)
me_resp = requests.get(f"{BASE_URL}/users/me", headers=headers)
me = me_resp.json()
print(f"   Role: {me['role']}")

# 4. Create project (admin only)
print("\n4. Creating project...")
project_resp = requests.post(
    f"{BASE_URL}/projects/",
    headers=headers,
    json={
        "name": "Book Digitization",
        "description": "Scanning historical books"
    }
)
project = project_resp.json()
print(f"   Project: {project['name']} (ID: {project['id']})")

# A capture must go into a volume with a file name stem (409 otherwise).
volume_resp = requests.post(
    f"{BASE_URL}/collections/",
    headers=headers,
    json={
        "name": "Volume 1",
        "project_id": project['id'],
        "filename_stem": "book-digitization-001"
    }
)
volume = volume_resp.json()
print(f"   Volume: {volume['name']} (ID: {volume['id']})")

# 5. List devices
print("\n5. Listing cameras...")
devices_resp = requests.get(f"{BASE_URL}/cameras/devices", headers=headers)
devices = devices_resp.json()
if devices:
    for dev in devices:
        status = "calibrated" if dev['calibrated'] else "needs calibration"
        print(f"   [{dev['index']}] {dev['model']} - {status}")
else:
    print("   No cameras detected (run on Raspberry Pi)")

# 6. Capture image (creates RecordImage automatically)
print("\n6. Capturing image...")
capture_resp = requests.post(
    f"{BASE_URL}/cameras/capture",
    headers=headers,
    json={
        "project_name": "Book Digitization",
        "collection_id": volume['id'],
        "camera_index": 0,
        "resolution": "medium"
    }
)
capture_result = capture_resp.json()
if capture_resp.status_code != 200:
    # Refused before any camera is triggered: 409 for no volume or no stem, 404 or 422 otherwise.
    print(f"   Capture refused ({capture_resp.status_code}): {capture_result['detail']}")
elif capture_result['success']:
    print(f"   Captured: {capture_result['file_path']}")
else:
    print(f"   Capture failed: {capture_result.get('error')}")

    # Fallback: create record manually
    rec_resp = requests.post(
        f"{BASE_URL}/records/",
        headers=headers,
        json={
            "title": "Ancient Manuscript",
            "capture_mode": "single",
            "author": "Unknown Scribe",
            "date": "1500-01-01",
            "collection_id": volume['id']
        }
    )
    rec = rec_resp.json()
    print(f"   Created record: {rec['title']} (ID: {rec['id']})")

# 7. List records (gallery)
print("\n7. Fetching gallery...")
list_resp = requests.get(
    f"{BASE_URL}/records/",
    headers=headers,
    params={"limit": 50}
)
records = list_resp.json()
print(f"   Total records: {len(records)}")
for r in records[:3]:
    print(f"   - {r['title']}: {r['capture_mode']}")

print("\nWorkflow complete!")
```

---

### Configuration Page Example

```python
def configuration_page_flow(token):
    """Flow for the configuration/setup page: cameras and calibration."""
    headers = {"Authorization": f"Bearer {token}"}

    # Step 1: Get available cameras
    devices = requests.get(f"{BASE_URL}/cameras/devices", headers=headers).json()
    print(f"Devices: {len(devices)} found")

    # Step 2: Run calibration if needed
    if devices and not devices[0]['calibrated']:
        cal_resp = requests.post(
            f"{BASE_URL}/cameras/calibrate",
            headers=headers,
            json={"camera_index": 0, "resolution": "high"}
        )
        result = cal_resp.json()
        if result['success']:
            print(f"Calibrated: lens_position={result['lens_position']}")
```

---

### Live Scan Page Example

```python
def live_scan_workflow(token, project_name, collection_id):
    """Workflow for the live scan page: capture → auto-save → optional metadata update.

    collection_id must name a volume that has a filename_stem: a capture
    without one, or into a volume without a stem, is refused with 409 before
    any camera is triggered (_refuse_capture_without_volume_or_stem, cameras.py:57-81).
    _resolve_capture_target then resolves the path from the volume and never
    reads project_name (cameras.py:151-170).
    """
    headers = {"Authorization": f"Bearer {token}"}

    # 1. Get cameras
    devices = requests.get(f"{BASE_URL}/cameras/devices", headers=headers).json()
    if not devices:
        print("No cameras detected")
        return
    selected = devices[0]
    print(f"Selected: [{selected['index']}] {selected['model']}")

    # 2. Capture (automatically creates RecordImage, CameraSettings, ExifData)
    capture_resp = requests.post(
        f"{BASE_URL}/cameras/capture",
        headers=headers,
        json={
            "project_name": project_name,
            "collection_id": collection_id,
            "camera_index": selected['index'],
            "resolution": "medium"
        }
    )
    result = capture_resp.json()
    if capture_resp.status_code != 200:
        print(f"Capture refused ({capture_resp.status_code}): {result['detail']}")
        return
    if not result['success']:
        print(f"Capture failed: {result['error']}")
        return
    print(f"Captured: {result['file_path']}")

    # 3. Update the metadata of the record this capture created.
    #    Use record_id from the capture response — do NOT list records and
    #    take the first. An unfiltered GET /records/ orders by id ASCENDING
    #    (see list_records in records.py), so `limit=1` returns the OLDEST
    #    record in the database and patching it overwrites an unrelated page.
    #    With ?collection_id=N the order is sequence-then-id in the same
    #    function, so you get whatever the operator ranked first — also not
    #    your capture.
    rec_id = result.get('record_id')
    if rec_id:
        update_resp = requests.patch(
            f"{BASE_URL}/records/{rec_id}",
            headers=headers,
            json={
                "title": "Page 1 of Ancient Manuscript",
                "author": "Unknown Scribe"
            }
        )
        print(f"Updated: {update_resp.json()['title']}")
```

---

### Gallery/View Page Example

```python
def gallery_view(token):
    """Display all captured records grouped by capture mode."""
    headers = {"Authorization": f"Bearer {token}"}

    records = requests.get(
        f"{BASE_URL}/records/",
        headers=headers,
        params={"limit": 100}
    ).json()

    print(f"Total Records: {len(records)}\n")

    # Group by capture mode ("single" or "dual")
    by_mode = {}
    for rec in records:
        by_mode.setdefault(rec['capture_mode'], []).append(rec)

    for mode, recs in sorted(by_mode.items()):
        print(f"\n{mode.upper()} ({len(recs)} items)")
        print("-" * 60)
        for rec in recs[:5]:
            print(f"  - {rec['title']}")
            print(f"    Author: {rec.get('author', 'N/A')}")
            print(f"    Images: {len(rec.get('images', []))}")
```

---

## 7. Frontend Integration

### Authentication Flow

```
1. GET /auth/setup/status                    (no auth)
   Response: { needs_setup: boolean }
   → true  = no user exists yet; route to first-run setup
     false = route to login
   The frontend calls this on the unauthenticated path, from the welcome
   and setup routes; an existing session in localStorage short-circuits
   straight to the dashboard without it.

2. POST /auth/register
   Request: { username, email, password }
   Response: { id, username, email, role, is_active, created_at }
   Note: first user becomes admin, all others become reviewer.
   Note: PUBLIC ONLY FOR THE FIRST USER. Once one account exists this
         endpoint requires an authenticated admin — 401 without a token,
         403 for a non-admin. Account creation is admin-controlled: an
         admin submits the new user's credentials directly. There is no
         invitation or token flow. Role is ignored if sent; elevate
         afterwards with PATCH /auth/users/{id}/role.

3. POST /auth/login
   Request: { username, password }
   Response: { access_token, token_type }

4. Store token: localStorage.setItem("access_token", access_token)

5. GET /users/me
   Headers: { Authorization: Bearer <token> }
   Response: { id, username, role, ... }
   → Use role to determine which UI sections to show:
     - admin:    full dashboard + user management panel
     - operator: full dashboard, no user management
     - reviewer: cannot create or edit records, projects or collections,
       BUT is not passive — reviewers drive the QA workflow, annotating
       records and moving them in_review -> approved / rejected
       (approval: STATUS_TRANSITIONS, schemas/record.py:64-70;
       rejection is its own route, POST /records/{id}/reject, records.py:1550), and may trigger a BagIt export
       (export_collection_bagit, collections.py:1342). They cannot send a
       record back to captured: rejected -> captured is operator/admin, and
       there is no approved -> captured for anyone -- an approved record goes
       back to in_review first (reviewer/admin).
       Note each router defines its own allow_read_only — the one in
       records.py governs records; the one in auth.py governs only auth
       endpoints.

6. Use token in all protected requests:
   headers: { "Authorization": `Bearer ${token}` }

7. Before expiry (8 hours by default — ACCESS_TOKEN_EXPIRE_SECONDS), refresh:
   POST /auth/refresh
   Headers: { Authorization: Bearer <old_token> }
   Response: { access_token, token_type }

8. On logout, clear BOTH keys:
   localStorage.removeItem("access_token")
   localStorage.removeItem("auth_user")
   The client stores the user alongside the token (stores/auth.ts:63),
   and the two keys hydrate independently, so half-cleared state is
   reachable. The hazard is a leftover TOKEN, not a leftover user:
   isAuthenticated() tests token !== null alone (stores/auth.ts:89,
   101), so a session with auth_user removed still reads as
   authenticated, with userRole silently null. (The root route is
   stricter: a token with no user is cleared and the client is sent to
   /welcome — routes/+page.svelte:22.)
```

---

The three capture-side pages — system configuration at `/dashboard/config`, capture at `/live-preview`, and the collection view at `/dashboard/projects/{projectId}/collections/{collectionId}` — used to be described here with the API calls each makes. The lists were wrong in substance when they were checked, as the endpoint table above was. The frontend source under `frontend/src/routes/` is the reference for what a page calls; the sections below cover only what the backend enforces regardless of which page is calling.

---

### Projects & Collections Page

**API Calls:**
1. `GET /projects/` — List projects (reviewer+)
2. `POST /projects/` — Create project (admin only)
3. `POST /projects/{id}/initialize` — Init filesystem (operator+)
4. `GET /collections/?project_id={id}` — List top-level collections (reviewer+)
5. `GET /collections/{id}/hierarchy` — Full collection tree (reviewer+)
6. `POST /collections/` — Create a volume (operator+, admin only in fisqua mode; `filename_stem` required; `project_id` ignored while projects are hidden — section 3, The unit's mode)
7. `GET /projects/{id}/records` — List project records (reviewer+)
8. `POST /imports/digitisation-list` — Import a digitisation list (operator+, admin only in fisqua mode; while projects are shown, a list whose project does not exist, admin only)
9. `GET /imports/digitisation-list/{list_id}/report` — Latest stored import report (reviewer+)
10. `GET /imports/digitisation-lists` — Imported lists, with their items and the volume each item names (reviewer+)

---

### User Management Page (Admin only)

**API Calls:**
1. `GET /auth/users` — List all users
2. `PATCH /auth/users/{id}/role` — Promote/demote user
3. `PATCH /auth/users/{id}/active` — Activate/deactivate user
4. `DELETE /auth/users/{id}` — Delete user

---

## 8. Configuration

### Environment Variables (`.env`)

```env
# Database — the backend builds its connection URL from these
DATABASE_USER=user
DATABASE_PASSWORD=password
DATABASE_HOST=db
DATABASE_PORT=5432
DATABASE_NAME=digitization_toolkit

# Optional, Alembic only: if set, migrations use this verbatim instead of
# building the URL from the DATABASE_* values above (alembic/env.py).
# The application itself never reads it. Note the +psycopg driver — a bare
# postgresql:// URL selects psycopg2, which is not installed.
DATABASE_URL=postgresql+psycopg://user:password@localhost:5432/digitization_toolkit

# Security
SECRET_KEY=change-this-to-a-random-string
ACCESS_TOKEN_EXPIRE_SECONDS=28800
```

The repository root `.env.example` is the authoritative list of supported variables; the block above shows only those relevant to the API. Keep the two in step — a variable the backend does not read belongs in neither.

The server host and port are not configurable by environment: the pixi `start` and `dev` tasks hardcode `--host 0.0.0.0 --port 8000`, so the native backend listens on every interface.

What keeps port 8000 off the venue LAN is the host firewall installed by `scripts/setup-firewall.sh`: ufw defaults to deny-inbound and allows 8000/tcp only from the appliance's own compose network (`172.30.0.0/24`), so Nginx can reach the backend and nothing else on the LAN can. Nginx itself is a reverse proxy, not a filter — it restricts nothing on its own. Container ports are handled separately, because Docker's iptables chains sit ahead of ufw's — but only some are loopback-bound. `docker-compose.yml` binds the database to `127.0.0.1:5432` and the production frontend to `127.0.0.1:3000`, while the backend service publishes `8000:8000` and the dev overlay publishes `5173:5173`, both on all interfaces. On a development machine on an untrusted network, those two are exposed.

Changing the address the backend actually binds to, as opposed to filtering access to it, means editing the uvicorn invocation in `backend/pixi.toml`.

### `CAPTUA_` and `DTK_` names

Every backend setting read under a `DTK_` name is also read under the `CAPTUA_` name with the same suffix: `CAPTUA_OFFSITE_TENANT` for `DTK_OFFSITE_TENANT`, and so on. Each such field of `Settings` declares both names through `_names` (`app/core/config.py:30-32`). There are twenty-five suffixes: `DATA_DIR`, `LOG_DIR`, `LOG_LEVEL`, `EXPORTS_DIR`, `MAX_UPLOAD_BYTES`, `OFFSITE_REMOTE`, `OFFSITE_DB_PREFIX`, `OFFSITE_TENANT`, `OFFSITE_READ_REMOTE`, `OFFSITE_DUMP_RECIPIENT`, `OFFSITE_BWLIMIT`, `RCLONE_BIN`, `RCLONE_CONFIG`, `PG_DUMP_COMMAND`, `OFFSITE_BACKUP_DELAY`, `OFFSITE_BACKUP_INTERVAL`, `OFFSITE_HOLD_FILE`, `FISQUA_ENV`, `FISQUA_BASE_URL`, `FISQUA_TOKEN`, `FISQUA_RETRY_BASE`, `FISQUA_RETRY_MAX`, `FISQUA_POLL_INTERVAL`, `FISQUA_TIMEOUT` and `FISQUA_ROTATE_DEG` (`app/core/config.py:75-170`). The suffix is the variable's, not always the setting's: `CAPTUA_EXPORTS_DIR` sets `EXPORTS_ROOT` (`app/core/config.py:90`), and the table below gives the setting of each offsite and Fisqua name, such as `OFFSITE_BACKUP_DELAY_SECONDS` for `DTK_OFFSITE_BACKUP_DELAY`. Settings without a prefix (`APP_ENV`, `DATABASE_*`, `PROJECTS_ROOT`, `CAMERA_BACKEND`, `SECRET_KEY`, `BOOTSTRAP_TOKEN`, `ACCESS_TOKEN_EXPIRE_SECONDS`, `CORS_ORIGINS` and `APP_VERSION`) have one name only.

When both names of a setting are set, the `CAPTUA_` value is used, wherever each is set: a `CAPTUA_` name in `.env` or `offsite.env` wins over a `DTK_` name in the process environment. Within each family the process environment wins over the files, and `offsite.env` over `.env` (`settings_customise_sources`, `app/core/config.py:198-221`). So a `CAPTUA_OFFSITE_TENANT` in `.env` overrides the `DTK_OFFSITE_TENANT` that `scripts/provision-rclone.sh` writes to `offsite.env`. The script writes `DTK_` names only, because a rollback restores code that reads only those (`app/core/config.py:18-22`). A `CAPTUA_` name set to an empty value is set, and it hides the `DTK_` name, because the sources are read in that order (`app/core/config.py:214-221`). For a text setting the empty value is used. The backend cannot read an empty value into a number or boolean setting: for `MAX_UPLOAD_BYTES`, `OFFSITE_BACKUP_DELAY`, `OFFSITE_BACKUP_INTERVAL`, `FISQUA_RETRY_BASE`, `FISQUA_RETRY_MAX`, `FISQUA_POLL_INTERVAL` and `FISQUA_TIMEOUT` (numbers) and `FISQUA_ROTATE_DEG` (a boolean), an empty `CAPTUA_` value makes `Settings()` raise a validation error when `app.core.config` is imported, and the backend cannot be started (`app/core/config.py:92`, `:130-131`, `:157-163`, `:170`, `:391`).

At startup the backend logs at `INFO` which `CAPTUA_` and `DTK_` names are set, and logs a `WARNING` for each setting whose two names are set to different values, naming the `CAPTUA_` one as the one used. It logs names, never values (`log_environment_names`, `app/core/config.py:366-388`, called in `app/main.py:16`).

`CAPTUA_SKIP_SCHEMA_CHECK` is read apart from `Settings`, from the process environment only. When it is set, to any value, it is used, and `DTK_SKIP_SCHEMA_CHECK` is read only when it is not (`_skip_requested`, `app/core/schema.py:30-34`).

---

### Offsite Copies

The offsite image upload, the catalogue dump, and restore (section 3 and section 5, Offsite copies) are configured by these variables. The backend reads them from `.env` and from `/var/lib/dtk/offsite.env`; a key in `offsite.env` wins over the same key in `.env`, and a variable in the backend's process environment wins over both (`app/core/config.py:176-221`). `scripts/provision-rclone.sh` writes `offsite.env` whole, with up to eight keys: `DTK_RCLONE_BIN` always, and `DTK_RCLONE_CONFIG`, `DTK_OFFSITE_REMOTE`, `DTK_OFFSITE_READ_REMOTE`, `DTK_OFFSITE_TENANT`, `DTK_OFFSITE_DUMP_RECIPIENT`, `DTK_FISQUA_TOKEN` and `DTK_FISQUA_ENV` each only when the run was given it or found it already recorded there. A key it leaves out overrides nothing in `.env` (`scripts/provision-rclone.sh:997-1154`). The tenant is given with `--tenant`, and replacing a recorded tenant also needs `--change-tenant`; the recipient is given with `--dump-recipient`, and the Fisqua environment with `--fisqua-env production` or `--fisqua-env staging` (`scripts/provision-rclone.sh:247-271`). The script takes the token only from a `FISQUA_TOKEN=` line in the key file named by `DTK_OFFSITE_KEY_FILE`; it is never printed, and it is refused unless it is exactly 64 lowercase hexadecimal characters (`valid_fisqua_token`, `:710-713`; `:2868-2890`). It is not taken under `--advisory`, the mode in which the update script calls this one, and it is refused when no tenant or no Fisqua environment is given or recorded (`scripts/provision-rclone.sh:150-178`, `:2870-2877`, `:2894-2915`). The read remote is written when a read key, `READ_KEY_ID` and `READ_APP_KEY`, is supplied in the key file named by `DTK_OFFSITE_KEY_FILE`, as a second section of the same rclone config, named `b2read` (`:124-148`, `:412-417`, `:1647-1804`). A read remote already recorded is carried forward. It is refused when it names the upload remote, and, when the upload remote is kept, when it is on another bucket; it is dropped when it is on another bucket than an upload remote this run writes, or names a section the config this run wrote does not hold (`reconcile_recorded_read_remote`, `:1594-1641`). The script checks the tenant and the dump recipient by the rules the backend applies to them, checks every value against its own character classes, and refuses to write a value shaped like an age private key (`:124-126`, `:603-758`, `:1003-1017`). `.env.example` lists all of them.

| Variable | Setting | Default | Meaning |
|---|---|---|---|
| `DTK_OFFSITE_REMOTE` | `OFFSITE_REMOTE` | empty | The rclone destination, a remote and a bucket (`b2unit:<bucket>`). Empty disables the image upload and the dump. |
| `DTK_OFFSITE_TENANT` | `OFFSITE_TENANT` | empty | The tenant prefix every object is keyed under, and Fisqua's tenant slug: 1 to 63 lowercase letters, digits and single hyphens, starting with a letter, and none of `platform`, `www`, `api`, `admin` or `app`. Empty disables the image upload and the dump; any other value that is not a prefix is the `misconfigured` state (section 3). |
| `DTK_OFFSITE_READ_REMOTE` | `OFFSITE_READ_REMOTE` | empty | A second rclone remote and bucket whose key may read objects under the tenant prefix. Only restore reads through it; empty, the restore route answers `409`. |
| `DTK_OFFSITE_DUMP_RECIPIENT` | `OFFSITE_DUMP_RECIPIENT` | empty | The age X25519 public key (`age1...`) every catalogue dump is encrypted to. Empty or invalid, no dump is written. |
| `DTK_OFFSITE_DB_PREFIX` | `OFFSITE_DB_PREFIX` | `db-backups` | The dump's directory under the tenant prefix. |
| `DTK_OFFSITE_BWLIMIT` | `OFFSITE_BWLIMIT` | `750k` | rclone's `--bwlimit` for every offsite transfer. |
| `DTK_OFFSITE_BACKUP_DELAY` | `OFFSITE_BACKUP_DELAY_SECONDS` | `300` | Seconds from the start to each schedule's first run. |
| `DTK_OFFSITE_BACKUP_INTERVAL` | `OFFSITE_BACKUP_INTERVAL_SECONDS` | `1800` | Seconds between runs. |
| `DTK_OFFSITE_HOLD_FILE` | `OFFSITE_HOLD_FILE` | empty, meaning `offsite-hold` in `DTK_DATA_DIR` | While this file exists, no image or dump is uploaded and a free is refused (section 3, The upload hold). |
| `DTK_FISQUA_ENV` | `FISQUA_ENV` | empty | `production` or `staging`, which picks the host `<tenant>.fisqua.org` or `<tenant>.staging.fisqua.org`. Empty, Fisqua is not configured (section 3, Delivery to Fisqua). |
| `DTK_FISQUA_BASE_URL` | `FISQUA_BASE_URL` | empty | Replaces the host, for tests and development; used only when `https://`, or `http://` to a loopback host. |
| `DTK_FISQUA_TOKEN` | `FISQUA_TOKEN` | empty | This unit's token, 64 lowercase hexadecimal characters. Held as a secret; never logged or returned. |
| `DTK_FISQUA_RETRY_BASE` | `FISQUA_RETRY_BASE_SECONDS` | `300` | Seconds before a failed send is tried again; doubled after each further failure. |
| `DTK_FISQUA_RETRY_MAX` | `FISQUA_RETRY_MAX_SECONDS` | `21600` | The longest backoff between attempts; a longer `Retry-After` from Fisqua wins. |
| `DTK_FISQUA_POLL_INTERVAL` | `FISQUA_POLL_INTERVAL_SECONDS` | `600` | Seconds between status polls. |
| `DTK_FISQUA_TIMEOUT` | `FISQUA_TIMEOUT_SECONDS` | `60` | Read and write timeout of each call to Fisqua, in seconds; connecting has 10. |
| `DTK_FISQUA_ROTATE_DEG` | `FISQUA_ROTATE_DEG` | `false` | When `true`, each image of the capture manifest with a recorded `rotate_deg` carries it as `rotateDeg`; when `false`, no image carries `rotateDeg`. The manifest declares contract `1.9` either way (section 3). Part of the configuration fingerprint (`config_fingerprint`, `app/core/fisqua_outbox.py:216-235`). |
| `APP_VERSION` | `app_version` | unset | Overrides the release read from `VERSION` (section 3, Version reporting). |
| `DTK_RCLONE_BIN` | `RCLONE_BIN` | `rclone` | The rclone executable. |
| `DTK_RCLONE_CONFIG` | `RCLONE_CONFIG` | empty | When set, passed to rclone as `--config`. |

The offsite settings are declared in `app/core/config.py:94-138` and the Fisqua ones in `:140-170`; `DTK_OFFSITE_TENANT` is checked in `configured_tenant` (`app/core/image_upload.py:137-161`), `DTK_OFFSITE_DUMP_RECIPIENT` in `dump_recipient` (`app/core/catalogue_backup.py:131-153`), and `DTK_RCLONE_CONFIG` in `_rclone_argv` (`catalogue_backup.py:227-232`).

---

### Logging

The backend's own loggers, `app.*` and `capture.*`, write to stderr, which the journal records on the appliance. `DTK_LOG_LEVEL` (setting `LOG_LEVEL`) sets their level and defaults to `INFO`; a value that is not a logging level falls back to `INFO` with a warning (`app/core/config.py:80`; `configure_logging`, `app/core/logging_setup.py:113-146`, called at import in `app/main.py:14`). Before this, the INFO lines of those loggers, such as the startup `Volume layout:` report, reached no handler. `DTK_LOG_DIR` is a different setting: the folder of the rotating capture logs, which the `capture_service` and `project_manager` loggers keep writing to.

### CORS Configuration

Allowed origins come from the `CORS_ORIGINS` environment variable, bound in `app/core/config.py` and applied in `app/main.py` (`allow_origins=settings.CORS_ORIGINS`). Set it in `.env` as a JSON array; it defaults to `http://localhost:5173` (Vite dev server) and `http://localhost:3000` (production Node server).

```env
CORS_ORIGINS=["http://localhost","http://localhost:5173","http://localhost:3000","http://captua.local"]
```

Do **not** edit `allow_origins` in `app/main.py` — it reads `settings.CORS_ORIGINS`, so a source edit is overridden by configuration.

On the appliance the frontend calls the API at the relative `/api` (`PUBLIC_API_BASE=/api` in `docker-compose.pi.yml`), and nginx on port 80 serves both, so every call is same-origin, whatever name or address the page was opened by, the kiosk's `http://localhost` included. CORS does not come into play there. It matters for the development stack, where the Vite page on `:5173` calls the backend on `:8000`, and for the code a rollback can restore: before 0.1.0 the frontend called `http://${HOST_IP}/api` and the kiosk opened `http://localhost:3000`, so those origins and the unit's names must stay listed. `setup.sh` and `update.sh` add `http://captua.local` (and keep `http://digitool.local` on a unit renamed from it) through `scripts/provision-hostname.sh`.

---

### Token Expiration

Default: 8 hours (28800 seconds), per `ACCESS_TOKEN_EXPIRE_SECONDS` in `app/core/config.py`. Change via `ACCESS_TOKEN_EXPIRE_SECONDS` in `.env`.

Deactivation does not wait for this: `get_current_user` checks `is_active` on every request (`app/api/auth.py:233`), so a deactivated user is refused on the next call to any route that depends on it. `POST /auth/password-reset` does not (`auth.py:206`, `:213`): it verifies the token and the old password and changes the password without checking `is_active`. What the expiry bounds is how long a token that has left its owner keeps working, so shorten it on units in shared spaces.

---

## Architecture Overview

### Security
- **Password Hashing**: PBKDF2-HMAC-SHA256 with 600,000 iterations (`PBKDF2_ITERATIONS`, `backend/app/core/security.py`). 100,000 is the *legacy* count, kept only to verify hashes stored before the format carried its own iteration count; login re-hashes those at the current count on the next successful sign-in.
- **Tokens**: HMAC-SHA256 signed, time-based expiration
- **Authentication**: HTTPBearer scheme with automatic dependency injection
- **Authorization**: Role-based via `RoleChecker` dependency (`admin`, `operator`, `reviewer`)
- **Bootstrap**: First registered user becomes admin; all others start as reviewer
- **User Status**: Inactive users cannot log in

### Database
- **ORM**: SQLAlchemy 2.0
- **Engine**: PostgreSQL
- **Relationships**: Proper foreign keys with cascading deletes
- **Timestamps**: not uniform. Most models carry `created_at`, but `ProjectMember` uses `added_at` instead (`models/project_member.py:16`). For modification times, `Record` has `modified_at` (`models/record.py`, without a line number: that file is under active edit and the number has moved three times) and `Collection` has `updated_at` (`models/collection.py:277`); no other model tracks one
- **Migrations**: Alembic. Automatic only in the dev container, whose command is `alembic upgrade head && uvicorn …`. Production runs `pixi run start`, a bare uvicorn; the Pi is migrated by `scripts/update.sh`, and `assert_schema_at_head()` fails startup if that has not happened

### Validation
- **Schemas**: Pydantic v2 for all inputs/outputs
- **Type Safety**: Full type hints throughout
- **Email Validation**: A basic format regex, deliberately — `pydantic[email]` is excluded to keep the appliance offline-capable (`schemas/user.py:19-39`)

### Extensibility
- **Custom Attributes**: JSON string for free-form record metadata
- **Camera Integration**: libcamera/picamera2 with hardware detection
- **Camera Registry**: Persistent calibration storage across system reboots
- **Dual Camera Support**: Synchronized captures for book scanning
- **Resolution Profiles**: Three DPI-optimized presets (low/medium/high)

## Support & Resources

- **FastAPI Documentation**: https://fastapi.tiangolo.com/
- **SQLAlchemy Documentation**: https://docs.sqlalchemy.org/
- **Pydantic Documentation**: https://docs.pydantic.dev/
- **Libcamera Documentation**: https://libcamera.org/
- **Picamera2 Documentation**: https://datasheets.raspberrypi.com/camera/picamera2-manual.pdf
- **Interactive API Docs**: http://localhost:8000/docs (when running)

---
