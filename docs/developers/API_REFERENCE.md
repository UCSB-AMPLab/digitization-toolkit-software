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

- **`422` has two meanings.** FastAPI's is a validation failure whose body is an object with a `detail` array. Twenty-two places in `backend/app/api/` raise their own, carrying a `detail` string or, on the handover and export refusals in `collections.py`, a dict — `{message, blocking_record_ids}`. The move refusal that names records the same way is a `409`, not a `422` (`collections.py:492-501`). And a refusal from the background export job never arrives as an error status at all: the job records it, and `GET .../export/status/{job_id}` returns it at `200` with the message in a top-level `error` field (`collections.py`). A client that reads every 422 as a malformed request misreports a volume refused for unapproved records.
- **`401` comes from one file, and `403` mostly does.** All fourteen 401s are in `app/api/auth.py`. Three are in `get_current_user`, the dependency of every route except `/health` and five auth routes, so a client can meet them anywhere. The other eleven are raised by the auth routes themselves — login, register, refresh and reset-password — for that route's own reason: a wrong password, a wrong bootstrap token at first-user registration (`_authorize_bootstrap`, called only there, `auth.py:63`), and at refresh and reset an invalid or expired token as well (`auth.py:172`, `:192`). The status code does not say whether the session has ended; the route and its message do. Three of the six 403s are in `auth.py` too, one of them `RoleChecker.__call__` (`auth.py:232`), the role gate routes declare as a dependency. Two are domain rules: an annotation with a recorded creator may only be deleted by that creator or an admin, and one with none by anyone who can reach the route (`records.py:972-975`); and `_apply_status_change` checks the caller's role (`records.py:1120-1123`). `_apply_status_change` is also called from `promote_collection`, so a role refusal can arrive from the handover — but the bulk status route calls it too and catches the refusal and returns `200` with the records it accepted — including a record already in the requested status, which is a no-op (`records.py:1110-1111`, `:1205-1210`); a refused record is logged on the server and not reported to the client. The sixth 403 is the list import's: an operator's list whose project does not exist yet is refused (`imports.py:98`).
- **`500` is a documented outcome, not only a crash.** Fifteen routes raise it deliberately: a camera control that failed, a storage command (`lsblk`, mount, unmount) that failed, a file operation that failed, or a database commit that failed after files had already changed. `POST /collections/{id}/images/renumber` writes no file, so its 500, `"The database update failed, so no record was renumbered. Please retry"`, leaves every sequence as it was (`collections.py:702-710`). When the commit of `POST /records/{id}/images` fails, the route unlinks the saved file and thumbnail before raising, and the line already appended to the volume's capture manifest stays (`records.py:549-578`). A failure after the commit, in the refresh at `records.py:579`, is also a 500 and cleans nothing up, so the two cannot be told apart from the status alone.

To re-derive this rather than trust it, which is what let the previous list go stale:

```bash
grep -rhoE 'HTTPException\(\s*(status_code\s*=\s*)?(status\.HTTP_)?[0-9]{3}|status_code\s*=\s*(status\.HTTP_)?[0-9]{3}' backend/app/ \
  | grep -oE '[0-9]{3}' | sort -u
```

Then drop the success codes the decorators declare — 200, 201, 202, 204. One raiser sits outside `backend/app/api/`: `app/core/db_errors.py`, which turns any `IntegrityError` — not only a unique-constraint one — into a 409 carrying a message and, when one could be recovered, the constraint name. For any single route, read it: the `HTTPException` calls are explicit, and sixteen callables in `backend/app/api/` raise on a route's behalf — `_authorize_bootstrap`, `get_current_user` and `RoleChecker.__call__` in `auth.py`; `_zone` in `activity.py`; `_refuse_capture_without_volume_or_stem`, `_refuse_retake_out_of_the_operators_hands`, `_refuse_resolution_in_filename`, `_resolve_capture_target` and `_take_filename_index` in `cameras.py`; `_read_capped` in `imports.py`; `_refuse_a_name_that_is_a_stem` and `_update_project_held` in `projects.py`; `_stored_master`, `assert_movable`, `_assert_promotable` and `_apply_status_change` in `records.py` — so a route can return a code its own body never names.

A hand-written endpoint table, data-model list and error-code table used to be kept here. By the time they were checked they covered barely half the API, documented three roles incorrectly, and presented one error shape as universal, when capture endpoints report failure as `{success: false, error: ...}` at HTTP 200. They were removed rather than repaired.

What remains here is what a schema cannot express: how to get the stack running, how to test it, how storage is laid out, worked examples, and the reasoning behind the architecture.

**A volume's identity — on `/collections` requests and responses.** A volume (a row in `collections`) carries the identity defined by exchange contract 1.1: a file name stem and the catalogue item's reference code. Records have no catalogue identifier: `records.external_id` was removed in migration `a7c1e9d2b4f6`. The schema gives the pattern and the lengths; the rules below are the ones it cannot state.

- **`filename_stem`.** The slug that, under exchange contract 1.1, the volume's image file names are built from (`<stem>-img_<nnnn>_c<n>`), and which the contract requires to equal the volume's reference code. New captures and uploads are named from it (see Filename Format below). A lowercase slug (`^[a-z0-9]+(-[a-z0-9]+)*$`) of at most 27 characters, so that `<stem>-img_0000` fits the 36-character pair id; a stem that does not match, or is longer, is refused with FastAPI's validation `422`. Required on `POST /collections/`: `CollectionCreate` declares it without a default (`app/schemas/collection.py:69`), so a request without one is refused with FastAPI's validation `422`. Optional on `PATCH /collections/{id}`, and the column is nullable, so that a volume created before stems existed can be given one. Unique on the unit; a duplicate is refused with `409`, naming the constraint `collections_filename_stem_key`. Before the volume has captured, a `PATCH` can set, change or clear the stem; a volume whose stem is cleared cannot be captured into until it is given another. A `NULL` stem can be set at any time, including on a volume that already has images. Once a volume has a stem and has captured (`capture_counter` above 0, or any image on its own records, superseded ones included), a request to change or clear the stem is refused with `409`.
- **The stem names a directory.** A volume with a stem keeps its files in `<projects root>/<stem>/`, beside the project directories (section 5). So a stem is refused with `409` when it equals a project's directory name, or when `<projects root>/<stem>/` exists, holds a file, and the volume has no image there (`stem_directory_conflict`, `app/models/collection.py:111-143`). `POST /collections/` and `PATCH /collections/{id}` check this first and answer with `{message}` in `detail` (`app/api/collections.py:129-132`, `:337-341`). `POST /projects/` and `PUT /projects/{id}` refuse a project name whose directory would be a volume's stem with `409` and a plain-string `detail` (`_refuse_a_name_that_is_a_stem`, `app/api/projects.py:160-164`). A `before_flush` listener refuses the same collisions from any other writer (`app/models/collection.py:474`), and `app/main.py:111-114` answers it with `409` and `{message}` in `detail`. No file is moved when a stem is set. New captures and uploads into the volume are written to `<stem>/captures/` at once; the backend moves the volume's existing files at its next start (section 5).
- **A capture needs a volume with a stem.** `POST /cameras/capture` and `POST /cameras/capture/dual`, retakes included, refuse a request before any camera is touched (`app/api/cameras.py:785-799`, with `_refuse_capture_without_volume_or_stem`, `:48-72`, and `_refuse_retake_out_of_the_operators_hands`, `:76-86`). After FastAPI's own validation of the body, the checks run in this order, and the first that fails gives the answer: `include_resolution_in_filename` set to `true`, `422` with `"A capture's file name cannot carry its resolution: the exchange contract fixes the name."` (`:130-133`); a `record_id` that matches no record, `404` with `"Record N not found"`; no `collection_id`, or `0`, `409` with `"Captures must go into a volume."`; a `collection_id` that matches no volume, `404`; for a retake (a request with a `record_id`), a record that belongs to no volume, the same `409`, and a record in a volume other than the one named, `409` with `"A retake must go into the record's own volume."`; then a volume without a stem, `409` with `"This volume has no file name stem. Give it one before capturing into it."`; then a retake of a record in review or approved, `409` with `"Only a captured or rejected record can be retaken."`; then a retake in the other capture mode, `422`. A retake that names another volume without a stem therefore gets the retake message. After the camera connection check, and before the shot, the capture's file name is taken (`_take_filename_index`, `:110-127`). It is refused with `409` and `"This volume has reached the limit of 9999 captures. A new volume is needed. Nothing was captured."` when the volume's next capture number would be above 9999, including while numbers already taken are passed over, and with `"The next capture numbers of this volume are already taken by files on disk. Nothing was captured."` when more than 100 numbers in a row are taken (`app/core/capture_naming.py:34-48`, `:178-216`). A refused name is rolled back and uses no number. A retake supersedes the record's current images; a rejected record returns to `captured`, and a captured one stays `captured` (`cameras.py:968-971`, `:1213-1215`). `POST /records/{id}/images` refuses an upload on the same terms: a record attached straight to a project with the first message and a volume without a stem with the second, before anything is written (`app/api/records.py:452-455`), and a name that cannot be taken with the same two `409`s as a capture, the 9999 limit included, before it writes any file (`:486-490`). By then `ensure_volume_dirs` has created the volume's directories (`:478`). The details are plain strings, defined in `app/core/volume_stem.py:22-25` and `app/core/capture_naming.py:43-48`. The stem is read under `SELECT … FOR UPDATE` on the volume row (`locked_volume_query`), and `PATCH /collections/{id}` takes the same row lock through `_locked_collection_query` (`app/api/collections.py:63-65`, `:313`), so on PostgreSQL a `PATCH` that sets or clears the stem waits until the capture's transaction commits. On SQLite neither query adds a lock clause. `POST /cameras/test-capture/{camera_index}` stores nothing and is not refused.
- **`external_id`.** The item's `referenceCode` under the exchange contract. Stripped of surrounding whitespace in requests; a blank value is refused with FastAPI's validation `422` (a `detail` array). Unique; a duplicate is refused with `409`, naming `ix_collections_external_id`. Written once: a request to change or clear a stored value is refused with `409`.
- **`capture_counter`.** Read-only. It is raised for each capture event (a dual capture is one event) and for each upload into a volume, by `take_filename_index` (`app/core/capture_naming.py:178-216`), which calls `next_capture_number` in `app/core/capture_counter.py`, a single atomic `UPDATE … RETURNING`, once more for each number it passes over. It is never lowered.
- **`stem_reserved`.** Read-only: the volume has a stem and has captured. A `DELETE /collections/{id}` on such a volume is refused with `409`, even when the volume is empty, so its stem cannot be issued again.
- `date`, `date_start`, `date_end`, `sequence` and `custom_attributes` describe the volume. An end date before its start is refused with `422` when both are in the request, and with `409` when the end is checked against a stored start.

Refused identity changes and the delete refusal return `409` with `{message}`; constraint violations return `{message, constraint}`. Both rules are in `app/models/collection.py`. The write rules are attribute validators, so they apply to every ORM assignment. The delete refusal is a `before_flush` listener, so it also applies to `session.delete()`, to the delete cascades from `Project.collections` and `Collection.child_collections`, and to delete-orphan. A bulk `query().update()`, raw SQL or a database-level `ON DELETE CASCADE` goes around both.

**A volume's record order — `records.sequence`.** The records of a volume are ordered by their `sequence`. Under exchange contract 1.1, section 3, renumbering rewrites records' `sequence` and never renames a file: a file's name carries its capture number, and order is the records' `sequence` (`app/core/record_sequence.py:1-8`). Every path that puts a record into a volume or rewrites the order in one keeps the volume's sequences distinct.

- **A record added to a volume takes the next sequence.** A record created by `POST /cameras/capture` or `POST /cameras/capture/dual` (not a retake), a record created by `POST /records/` with a `collection_id`, and a record moved to another volume by `PATCH /records/{id}` take the sequence after the highest in that volume; in a volume with no sequenced record the first is `1` (`next_sequences`, `record_sequence.py:140-158`; `app/api/cameras.py:34-45`, `:905`, `:1119`; `app/api/records.py:194-204`, `:346-355`). `POST /records/` does not use a `sequence` in the body, and gives no sequence to a record outside a volume or to one naming a volume that does not exist. `PATCH /records/{id}` takes no `sequence` in its body; a `sequence` sent there is ignored (`RecordUpdate`, `app/schemas/record.py:211-218`). A retake keeps its record's sequence. `POST /collections/{id}/move-records` gives the moved records the sequences after the target's highest, in their listing order in the source (`collections.py:520-533`). In each case the volume's row is locked before the highest sequence is read and stays locked until the commit.
- **`POST /collections/{id}/images/renumber`.** Admins and operators may renumber. The route sets the `sequence` of every record of the volume to 1..N in listing order: by `sequence`, records without one last, records that share one by id (`listing_order`, `record_sequence.py:46-48`; `renumber_volume_records`, `:106-119`). No file is renamed, moved or written, no manifest line is written, and records of other volumes are not touched. The response is `200` with `{renumbered: N}`, N being the number of records in the volume (`collections.py:675-715`). A volume that does not exist is refused with `404`. A failed commit is the `500` described above. The renumber is recorded in the activity log as `images_renumbered`.
- **`PATCH /collections/{id}/records/reorder`.** Admins and operators may reorder. The body is `{ordered_ids: [...]}`, and the list must name every record of the volume exactly once. Each record's `sequence` is set to its position in the list, counted from 1. An empty list is refused with FastAPI's validation `422` (`app/schemas/record.py:303-311`). A list that leaves a record out, repeats one or names a record of another volume is refused with the application's `422` and the plain-string detail `"ordered_ids must name every record of the volume exactly once."`, and nothing is written (`reorder_volume_records`, `record_sequence.py:122-137`; `collections.py:638-668`). The response is `200` with `{reordered: N}`. A volume that does not exist is refused with `404`.
- **Both answer `409` when the volume keeps changing.** Renumber and reorder lock the volume's records and then the volume's row. If a record was added to the volume between the two, the transaction is rolled back and the locking starts again. After five attempts that each found the volume's records changed, the request is refused with `409` and the plain-string detail `"The volume changed while it was being renumbered. Try again."` (`lock_volume_records`, `record_sequence.py:74-97`; `LOCK_ATTEMPTS` and the message, `:38-39`; `collections.py:661-663`, `:697-698`). Nothing is written. On SQLite no lock clause is emitted (`record_sequence.py:19-20`).
- **A renumber or reorder during an export fails the export.** Neither route is refused while an export of the volume is queued or running. When the export job has planned its payload, and before it writes anything, it compares each record's status, `sequence` and current images with what they were when the job passed its gate. If any differ, the job fails: `GET /collections/{id}/export/status/{job_id}` returns `state: "failed"`, the `error` `"Cannot export: the collection changed while the archive was being assembled (N record(s) affected). Try again."` and `detail: {blocking_record_ids}` (`app/core/export_service.py:103-108`, `:162-191`; `app/core/export_jobs.py:33-43`, `:166-169`).

**Importing a digitisation list — `POST /imports/digitisation-list`.** The route reads artefact 1 of exchange contract 1.1 and creates one volume per item; the route is in `app/api/imports.py` and the import in `app/core/list_import.py`. The request is a multipart upload with one field, `file`, carrying the list file unchanged. Admins and operators may import. Creating a project is admin-only, as on `POST /projects/`, so a list whose project does not exist yet is refused to an operator with `403` before anything is written (`list_import.py:741-742`).

- **Refused whole, with no volume or report written.** A file over 10 MiB (10,485,760 bytes) is refused with `413` (`imports.py:59-60`). A file that is not strict UTF-8 JSON (not UTF-8, not JSON, `NaN` or `Infinity`, a key repeated within one object, nesting too deep, a number too large to read) is refused with `400` (`parse_list_file`, `list_import.py:200-233`). So is a file in which any key or string holds an escaped lone surrogate, such as `\ud800`; an escaped surrogate pair is one character and is accepted (`_holds_lone_surrogate`, `:180-197`; `:228-232`). An envelope this unit does not read is refused with the application's `422`: a top-level value that is not a JSON object (`list_import.py:302-303`), a `contract` other than `fisqua-captua-exchange`, a `kind` other than `digitisation-list`, a `version` whose major is not `1`, an `id` that is not a UUID, a missing or blank `list.name`, one containing NUL (`:324-326`), or one longer than 255 characters once stripped and in NFC (`:327-328`), or `items` that are not a list (`check_envelope`, `list_import.py:295-333`). Unknown fields are ignored. A list id imported before from a file with a different SHA-256, or whose earlier hash cannot be read, is refused with `409`; a first import whose hash cannot be recorded, with `503` (`_check_hash`, `list_import.py:876-922`). A list that would create a project is also refused with `503` when the lock an import takes to look for and create its project when none exists, `<DTK_DATA_DIR>/imports/.project-create.lock`, cannot be taken; the detail is `"Captua could not take the lock that keeps two imports from creating the same project, so it did not import the list. Try again."`, and no project or volume is written. A list whose project exists is imported without that lock (`_project_for`, `list_import.py:510-546`, the lock at `:532-546`; `:236-268`; `imports.py:102-103`). Each body is `{detail}` with a string.
- **The project refusals and the list's hash.** Inside the list lock's block, whether or not the lock file could be made, and before the list's hash is written, `_refuse_list_before_hash` refuses the whole list when no project matches its name: from an operator with `403`, and from an admin with `422` when the project it would create would have a volume's stem as its directory name (`list_import.py:747`, `:850-863`). A refused file therefore leaves no hash, and a corrected file can be imported under the same list id. If `_project_for` fails after the hash was written, for any reason (a refusal, the project deleted between the check and its use, the project lock not taken, or a database error), the hash is removed when this run wrote it and holds the lock (`list_import.py:748-771`). Without the lock the hash is kept and a WARNING names its path; a corrected file under that id is then refused with `409` until the hash file is removed by hand. A hash that an earlier import recorded is never removed (`:762-770`; `_remove_hash_file`, `:866-873`, which logs a removal that fails).
- **The project.** The volumes are created directly under the project whose name matches `list.name`, compared stripped, in NFC and case-folded, with accents kept (`_name_key`, `list_import.py:392-398`); if several match, the oldest. If none matches, a project is created, and `list.notes` becomes its description when it is a non-blank string of at most 10,000 characters with no NUL (`list_import.py:405-419`). An existing project's description is never changed (`_project_for`, `list_import.py:437-475`).
- **The mapping.** `referenceCode` to `external_id`, `filenameStem` to `filename_stem`, `title` to `name`, `dates.display` to `date`, `dates.start` to `date_start`, `dates.end` to `date_end`, `sequence` to `sequence`. Every other item field, `containerPath` included, is stored in `custom_attributes` as a JSON string under a `fisqua` key, and `dates` subfields other than those three under `fisqua.dates` (`list_import.py:371-384`). No records are created.
- **Items are skip-and-report.** Each item is checked, then created and committed on its own, so no item is rolled back because another was rejected. The first failing check gives the reason, in this order: the item is not an object; the reference code is missing, not a string of at most 255 characters, padded with whitespace, or repeated earlier in the list; the stem is missing, not a slug, longer than 27 characters, not equal to the reference code, or repeated earlier in the list; the title is missing or invalid; the dates are invalid or end before they start; the sequence is not a 32-bit integer; a volume on the unit already has the reference code, or the stem (`_check_item`, `list_import.py:371-457`, and `:623-629`). A constraint violation at the insert or the commit is mapped by constraint name to the same reasons, or else to `refused_by_database`. The stem directory check at the insert gives two more: `filename_stem_is_project_directory` when the stem is a project's directory name, and `filename_stem_directory_occupied` when `<projects root>/<stem>/` already holds files (`list_import.py:125-136`, `:640-646`). Any other database failure on an item, in the two duplicate lookups, the insert or the commit, rejects that item as `refused_by_database`, and the import and its report go on (`:647-654`). The reason codes and their messages are `REASONS` and `_CONSTRAINT_REASONS` (`list_import.py:103-146`). The reference code is never stripped. Only the import requires the stem to equal the reference code; `POST /collections/` does not check it.
- **The report.** The response is `200` with the report: `listId`, `listName`, `projectId`, `projectName`, `projectCreated`, `projectNotesStored`, `projectNotesSkipped`, `importedAt`, `importedBy`, the counts `created` and `skipped`, `volumes` (each created volume's `position`, `referenceCode`, `filenameStem` and `captuaCollectionId`), `rejects` (each rejected item's `position`, `referenceCode` cut to 120 characters, `referenceCodeTruncated`, `reason` and `message`), `fileSha256` and `reportStored` (`list_import.py:483-494`, `:556-570`, `:667-674`). The report is also written, without `reportStored`, to `<DTK_DATA_DIR>/imports/<list-id>/import-report_<list-id>_run<NNNN>.json`, one numbered file per run, none overwritten (`store_report`, `list_import.py:891-932`). If that write fails, `reportStored` is `false` and the volumes stay created. The list's hash is kept beside the runs in a file named `sha256`. `GET /imports/digitisation-list/{list_id}/report` (admin, operator or reviewer) returns the highest-numbered run that parses as the list's report, as an attachment named `import-report_<list-id>.json`; an id that is not a UUID is refused with `422`, and a list with no readable report with `404` (`imports.py:116-135`). Each completed import is recorded in the activity log as `digitisation_list_imported`, at `WARN` when the report could not be stored; a refused import is not logged (`imports.py:102-111`).
- **Re-importing.** The same file can be imported again. Every item already on the unit is rejected as `reference_code_on_unit` (or `filename_stem_on_unit`), any other item is checked and created as on the first run, and the report is stored as the next run. A different file under the same list id is refused with `409`. Imports of one list id are serialised by an exclusive lock on `<DTK_DATA_DIR>/imports/<list-id>/.lock` (`import_list`, `list_import.py:599-674`); if the lock file cannot be created, the import runs unlocked and the failure is logged (`:715-719`). A re-import finds its project by name (`_find_project`, `:423-434`), so after the project has been renamed an operator's re-import is refused with `403`, and an admin's creates a new project.

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
└── ...
```

- **The stem decides the layout.** `image_output_dir()` (`backend/capture/project_manager.py:121-137`) returns `<projects root>/<stem>/captures/` for a volume with a stem, `<project dir>/<volume dir>/images/main/` for a volume without one, and `<project dir>/images/main/` for neither. `volume_root()` (`:77-97`) refuses a value that is not a stem, so a stored stem cannot name a path outside the root. Before a capture into a volume with a stem, all four directories are created (`ensure_volume_dirs`, `:100-107`; `backend/capture/service.py:331-334`). In the name-based layout two volumes of one name share a directory, and a nested volume's directory sits beside its parent's (`collection_capture_root`, `project_manager.py:110-118`). A volume without a stem takes no capture or upload (section 3), but a move of records into it, or a rename of it or of its project, still writes files there. An upload goes to `<stem>/captures/`, named as a single capture is (see Filename Format), and its thumbnail to `<stem>/thumbnails/` (`backend/app/api/records.py:477-491`).
- **A RAW master's preview is placed by the layout.** `preview_sidecar_of()` (`backend/app/core/paths.py:64-83`) names the `_preview.jpg` of a master in `captures/` in the sibling `previews/`, and that of any other master beside it.
- **Each volume with a stem has its own manifest.** `append_manifest_record()` (`backend/capture/manifestHandler.py:281-302`) writes `project_manifest.jsonl` at project init, in the project's `metadata/`, and one `manifest.jsonl` line per capture event, carrying each file's capture-time sha256. The capture line goes to the manifest under `capture_manifest_root()` (`project_manager.py:140-149`): `<stem>/metadata/manifest.jsonl` for a volume with a stem, the project's otherwise. Its paths are relative to the directory that holds `metadata/`. Each line is appended in one `O_APPEND` write and fsynced, after a newline when the last line was torn (`_append_line`, `manifestHandler.py:260-278`). An upload into a volume writes an upload record to `<stem>/metadata/manifest.jsonl` by the same append, before its row is committed: `{record_type: "upload", capture_id, timestamp_utc, files: [{role: "single", relative_path, bytes, mimetype, sha256}]}`, with the stored file's path, size, content type and sha256 (`append_upload_record`, `manifestHandler.py:349-385`; `backend/app/api/records.py:555-563`). Its `capture_id` is the one the client sent with the upload, or a uuid4 the route gives an upload sent without one, and the image row carries the same id (`records.py:498-499`). If the commit fails, the file and thumbnail are removed and the line stays, so the number it names is not given again. When a move, or the startup migration (see Moving volumes into the stem layout at startup), renames a master with a capture id, a relocation record, `{record_type: "relocation", capture_id, image_id, sha256, from, to, relocated_at}`, is appended to the manifest of the top directory the master was moved into (`append_relocation_record`, `manifestHandler.py:313-343`; `relocation_of`, `backend/app/core/storage_ops.py:54-81`; `_record_relocation`, `backend/app/core/volume_layout.py:909-934`). A renumber renames no file and writes no relocation record. With no capture-time checksum to carry, no record is written and a WARNING is logged. A project's manifest is not deleted with the project: `DELETE /projects/{id}` moves it to `.retired-manifests/<project dir>-<UTC timestamp>-manifest.jsonl` first, and refuses with `409` a tree that holds any other capture manifest (`backend/app/api/projects.py:407-421`, `retire_project_manifest`, `storage_ops.py:637-668`).
- **Old and new manifests are read together.** `build_fixity_index()` (`backend/app/core/integrity.py:126-228`) reads every `metadata/manifest.jsonl` under the projects root, each project's and each volume's, and the retired ones (`_manifests`, `:236-247`). Paths in a manifest are resolved against the directory that holds its `metadata/`, or, for a retired one, against the project directory its file name carries (`manifest_base`, `:250-262`). A capture record gives each file's sha256 by path and by file name, and an upload record is read as a capture record (`:132-134`); a relocation record that names its image gives that image's sha256 directly. A line that is not JSON is skipped, and the count is logged. The export fixity gate (`_fixity_gate`, `backend/app/core/export_service.py:233-259`) refuses the bag with `checksum_mismatch` when a file's bytes differ from its sha256, and with `checksum_unresolved` when an image's capture id has a capture record in some manifest but no sha256 resolves for the image; an image whose capture id has no capture record anywhere, such as an upload made before uploads were written to the manifest, passes unchecked, and a later upload is checked against its upload record (`verify_images_against_manifest`, `integrity.py:319-332`). The bag's `data/metadata/manifest.jsonl` holds the capture records of the volume's current images from every manifest, without relocation records; where both a capture-time record and a migration copy exist, the capture-time record is used. The upload records of the volume's current images are included as capture records are (`capture_record_lines`, `integrity.py:265-310`, with uploads at `:274-275`, `:295-297`; `export_service.py:195-197`, `:323-339`; `backend/app/core/bag_export.py:90`).
- **Renames and moves no longer touch migrated files.** No file in `<stem>/` is moved when the volume is renamed, re-parented or moved to another project, and when its project is renamed. Files still in the name-based layout, which are every file of a volume without a stem and those of a volume given a stem since the last start, are moved as before, and the operation is refused with `409` while an export of a volume with such files is queued or running (`collections_in_old_layout`, `storage_ops.py:240-263`; `backend/app/api/collections.py:373-381`; `projects.py:200-203`, `:316`, `:319`). `POST /collections/{id}/move-records` still moves the records' files, to the target's `<stem>/captures/` or to its name-based directory (`collection_image_dir`, `storage_ops.py:293-305`; `collections.py:471`). `DELETE /collections/{id}` removes only the volume's empty directories; a file found there that no row references stays where it is and is logged (`remove_empty_dirs`, `storage_ops.py:740-757`; `collections.py:602-610`).
- **`packages/` is not where exports go.** It is created at project init and nothing writes into it. BagIt exports are written to `settings.exports_dir`, `/var/lib/dtk/exports` by default (`backend/app/core/config.py:114-115`, `backend/app/core/export_service.py:112`).
- **There is no `temp/` or `trash/` directory under the projects root, and deletion is permanent.** Deleting a record unlinks its files, as does deleting a single image (`delete_record` and the image delete handler in `backend/app/api/records.py`); each takes the master, the thumbnail and the `_preview.jpg` sidecar where `preview_sidecar_of()` places it. There is no recovery directory, and on a backup-less appliance a delete is final.
- **The root is not fixed.** Activating an external storage device changes `settings.projects_dir` at runtime, so captures may live somewhere other than the default microSD path.

### Moving volumes into the stem layout at startup

Volumes captured before stems existed, and volumes given a stem later, have files in the name-based layout. At every start, after the project rename reconciliation, the backend runs `migrate_volume_layout_at_startup()` (`backend/app/main.py:42-47`; `backend/app/core/volume_layout.py:1523-1546`), and the migration moves the existing files of each volume with a stem into `<stem>/`. New captures and uploads into a volume with a stem are written to `<stem>/captures/` at once.

- **The rows decide what is moved.** An image row of a volume with a stem is out of place when its stored path is under the active projects root and not in the volume's `captures/` (`_expected_dirs` and `_out_of_place`, `volume_layout.py:268-304`). Nothing else is looked at: finding the rows takes one query for the stems, one over the image rows and a string comparison per row, with no filesystem access per row. The files of a volume without a stem are left where they are. Files are attributed by their rows, never by the directory they are in, so the migration separates two volumes of one name that share a directory.
- **What is moved, and where.** The migration moves a master to `captures/`, a RAW master's sidecar to `previews/` and a thumbnail to `thumbnails/`, and keeps their names. No file is moved onto an existing one. A master's name counts as taken when a file in `captures/` has it (compared case-folded), when its sidecar's name is taken in `previews/`, or when a file of another record in `captures/` has the same stem (`_Dir.master_taken`, `:328-334`). A master whose name is taken is renamed by inserting `_img<image id>` before its suffix, then `_img<image id>_2`, `_3` and on, so `20260109_143652_123_c0.jpg` of image 42 becomes `20260109_143652_123_c0_img42.jpg` (`_suffixed_stems`, `:361-368`; `:707-725`; `_free_name`, `:835-846`). A renamed master with a capture id gets a relocation record in the volume's manifest before it is moved (`_record_relocation`, `:909-934`). The migration moves only files under the active projects root, so uploads made before this layout, under `<DTK_DATA_DIR>/uploads/`, stay there and are skipped as `outside_projects_root` (`:628-629`).
- **A row whose file is already in place.** When a row's old path is gone, a file in the volume's `captures/` under the row's own name or one of the clash names, and that no row references, is adopted: the row is pointed at it, but only when its sha256 matches the capture-time checksum held for the image. Adopted rows are listed under `adopted`. With no matching checksum the image is skipped as `missing` (`_adoptable`, `:398-428`; `:681-701`).
- **Thumbnails.** A thumbnail whose name is taken in `thumbnails/`, or whose file is missing, has its row cleared, and the image is listed under `thumbnails_cleared` with the reason `name_taken` or `missing`; the thumbnail route regenerates it (`:739-753`, `:978-986`). A thumbnail that cannot be moved keeps its row and is listed under `thumbnails_not_moved`.
- **The volume's records are copied first.** Before the migration moves a volume's files, it copies the volume's capture records and their relocation records from every other manifest into `<stem>/metadata/manifest.jsonl`, marked `copied_from` and with their paths rebased onto `<stem>/`. The manifests they are copied from are not changed (`_copy_volume_records`, `:1108-1130`).
- **The journal.** The work is done one volume at a time. The migration writes the volume's planned moves to `<DTK_DATA_DIR>/volume-layout.journal` before it moves any file; after the moves it fsyncs the directories, commits the rows and removes the journal (`:1320-1326`; `_commit_batch`, `:1133-1145`). At startup the migration completes a journal it finds before anything else (`:1280-1295`).
- **When the backend does not serve.** Any `VolumeLayoutError` is re-raised and the backend does not serve: a pending journal that names another projects root, a journal or sidecar list that cannot be read (`:165-172`, `:193-196`), or a volume manifest that cannot be read while records are copied (`:1056-1060`). Another failure that leaves a journal is re-raised too. Any other failure is logged and the backend serves, as it does when the projects root cannot take writes (`:1533-1545`).
- **What is skipped or fails.** Each image the plan does not move is listed under `skipped` with a `reason`. A volume whose `<stem>/` already holds entries that are not the volume's is not moved; each of its images has the reason `stem_dir_occupied` and the list `foreign` (`_foreign_entries`, `:484-566`). A volume whose `<stem>/` is a live project tree has the reason `stem_dir_is_project_tree`. A stored stem that is not a valid stem gives `no_stem` (`:634-637`, `:648-650`). Single images can also be skipped as `outside_storage`, `outside_projects_root`, `missing` or `row_changed` (`:626-689`, `:895-938`). An image whose move fails is listed under `failed` with `image_id`, `path` and `error`; its file and row are left as they were, and the migration goes on with the next image (`:929-936`). A sidecar that cannot be moved with its master is listed under `sidecars_not_moved`, recorded in `<DTK_DATA_DIR>/volume-layout.sidecars`, retried at every start, and listed under `sidecars_pending` until it has been moved (`:957-963`; `_retry_sidecars`, `:1148`).
- **What else is reported.** A writer's temporary file in `<stem>/` is not counted as foreign; it is left where it is and listed under `temp_files_left`. A generated thumbnail (`<uuid4 hex>_thumb.jpg`) that no row owns is treated the same way and listed under `orphan_thumbnails_left`. On a run that finds out-of-place rows, the files no row references in the name-based volume directories, and in the directories files are moved out of, are listed under `left_unreferenced` and stay where they are (`_unreferenced_in_collection_dirs`, `:777-809`; `:1303`, `:1311`). So is a file that no row references and that took a name a master was denied, forcing the clash rename, in `captures/` or, for a RAW master, `previews/` (`_clashing_files`, `:337-358`; `:713-724`, `:761`), and a file that took a master's planned name after planning (`:916-922`). Such a file makes the volume's `<stem>/` hold what is not the volume's, so a later run that has more of the volume's files to move skips it as `stem_dir_occupied` until the file is removed. At every start each volume's leftover `metadata/manifest.jsonl.part`, written by an earlier version of the manifest copy, is removed and counted in `stale_parts_removed`; one that cannot be removed is counted too, and logged at ERROR (`_remove_stale_parts`, `:1332-1354`). After the moves, each migrated volume's own manifest is checked for a capture record per capture id of its images. The missing ones are copied in from the other manifests and counted per volume in `manifests_repaired`, and capture ids that no manifest holds are listed per volume in `captures_without_record` (`_repair_volume_manifests`, `:1357-1468`). The capture ids found in no manifest are kept in `<DTK_DATA_DIR>/volume-layout.missing-records` with each manifest's path, size and modification time, and the search of every manifest is skipped while both the missing ids and the manifests are unchanged (`:1427-1429`). The report's keys are set in `_new_report` (`:1230-1255`). At startup the findings are logged. `python -m app.core.volume_layout [--dry-run]`, run with the backend stopped, prints the report as JSON and exits with 1 when `failed` is not empty; a dry run writes nothing and lists a pending journal's entries under `pending_journal_entries` without completing it (`main`, `:1549-1570`; `:1288-1291`).

### Filename Format

New captures and uploads are named under exchange contract 1.1, section 3:

`<stem>-img_<nnnn>_c<n>.<ext>`

- `<stem>` — the volume's `filename_stem`
- `<nnnn>` — the volume's capture number, zero-padded to four digits, from `0001` to `9999`. `take_filename_index` refuses a number above 9999 (`backend/app/core/capture_naming.py:208-211`; `MAX_CAPTURE_NUMBER`, `:35`), and `capture_filename_index` formats the number it is given (`:62-68`)
- `c<n>` — the camera index (`c0`, `c1`); an upload is always `c0`
- `.<ext>` — the file's suffix

**Example**: `co-ahrb-aht-003-img_0001_c0.jpg` and `co-ahrb-aht-003-img_0001_c1.jpg`, the two images of one dual capture.

`<stem>-img_<nnnn>` is the capture event's filename index. Both images of a dual capture carry it, and it is their pair id; a single capture has no pair id (`backend/capture/service.py:398`, `:698`). A stem holds at most 27 characters and the number at most four digits, so the index always fits the 36-character `pair_id` column (`backend/app/models/record.py:131`; `backend/app/models/collection.py:9-17`). A RAW master's preview is `<stem>-img_<nnnn>_c<n>_preview.jpg`, in the volume's `previews/` (`preview_sidecar_of`). An upload is named `<stem>-img_<nnnn>_c0` with the client's suffix, lowercased, when it is `.jpg`, `.jpeg`, `.png`, `.tif`, `.tiff` or `.webp`, and otherwise the suffix of its content type; the name the client sent is logged at INFO with the name the file is stored under, and not kept (`_upload_suffix`, `backend/app/api/records.py:420-424`, `:491-493`).

`take_filename_index` (`capture_naming.py:178-216`) takes one number per capture event or upload, in the transaction that writes the event's images. It passes over a number that a file in the volume's `captures/` or `previews/` already carries, under any suffix and compared case-folded (`capture_name_taken` and `files_carrying`, `:71-115`), or whose `<stem>-img_<nnnn>_c` the volume's `metadata/manifest.jsonl` holds anywhere in its text, in capture, upload and relocation records alike (`manifest_capture_numbers`, `:140-175`, the match at `:146-152`). Numbers can be skipped; none is given twice. The refusals are listed in section 3. `capture_image` also refuses a name that a file took after the number was chosen (`service.py:346-347`); that `FileExistsError` reaches the client as `200` with `{success: false, error}`, and the transaction is rolled back (`backend/app/api/cameras.py:986-991`, `:1232-1237`).

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
`capture/service.py:650`), and both backends lock per camera index rather
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
    any camera is triggered (_refuse_capture_without_volume_or_stem, cameras.py:49-73).
    _resolve_capture_target then resolves the path from the volume and never
    reads project_name (cameras.py:89-108).
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
       (approval: STATUS_TRANSITIONS, schemas/record.py:55;
       rejection is its own route, POST /records/{id}/reject, records.py:970), and may trigger a BagIt export
       (export_collection_bagit, collections.py:800). They cannot send a
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
   The client stores the user alongside the token (stores/auth.ts:82),
   and the two keys hydrate independently, so half-cleared state is
   reachable. The hazard is a leftover TOKEN, not a leftover user:
   isAuthenticated() tests token !== null alone (stores/auth.ts:123,
   159), so a session with auth_user removed still reads as
   authenticated, with userRole silently null. (The root route is
   stricter: a token with no user is cleared and the client is sent to
   /welcome — routes/+page.svelte:28.)
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
6. `POST /collections/` — Create a volume (operator+; `filename_stem` required)
7. `GET /projects/{id}/records` — List project records (reviewer+)
8. `POST /imports/digitisation-list` — Import a digitisation list (operator+; a list whose project does not exist, admin only)
9. `GET /imports/digitisation-list/{list_id}/report` — Latest stored import report (reviewer+)

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

---

### CORS Configuration

Allowed origins come from the `CORS_ORIGINS` environment variable, bound in `app/core/config.py` and applied at `app/main.py:82-83`. Set it in `.env` as a JSON array; it defaults to `http://localhost:5173` (Vite dev server) and `http://localhost:3000` (production Node server).

```env
CORS_ORIGINS=["http://digitool.local","http://localhost:5173","http://localhost:3000"]
```

Do **not** edit `allow_origins` in `app/main.py` — it reads `settings.CORS_ORIGINS`, so a source edit is overridden by configuration.

In the production stack the browser reaches both the frontend and `/api/` through the Nginx reverse proxy on port 80, so it is a single origin and CORS does not come into play in normal use.

---

### Token Expiration

Default: 8 hours (28800 seconds), per `ACCESS_TOKEN_EXPIRE_SECONDS` in `app/core/config.py`. Change via `ACCESS_TOKEN_EXPIRE_SECONDS` in `.env`.

Deactivation does not wait for this: `get_current_user` checks `is_active` on every request (`app/api/auth.py:222`), so a deactivated user is refused on the next call to any route that depends on it. `POST /auth/password-reset` does not (`auth.py:181`, `:195`): it verifies the token and the old password and changes the password without checking `is_active`. What the expiry bounds is how long a token that has left its owner keeps working, so shorten it on units in shared spaces.

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
- **Timestamps**: not uniform. Most models carry `created_at`, but `ProjectMember` uses `added_at` instead (`models/project_member.py:14`). For modification times, `Record` has `modified_at` (`models/record.py`, without a line number: that file is under active edit and the number has moved three times) and `Collection` has `updated_at` (`models/collection.py:27`); no other model tracks one
- **Migrations**: Alembic. Automatic only in the dev container, whose command is `alembic upgrade head && uvicorn …`. Production runs `pixi run start`, a bare uvicorn; the Pi is migrated by `scripts/update.sh`, and `assert_schema_at_head()` fails startup if that has not happened

### Validation
- **Schemas**: Pydantic v2 for all inputs/outputs
- **Type Safety**: Full type hints throughout
- **Email Validation**: A basic format regex, deliberately — `pydantic[email]` is excluded to keep the appliance offline-capable (`schemas/user.py:15-21`)

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
