---
applyTo: "frontend/**"
---

# Material Icons Reference for DTK

## Usage

Material Icons are now available offline throughout the application. Simply use the icon name as text content within an element with the `material-symbols-outlined` class.

### Basic Usage

```html
<span class="material-symbols-outlined">home</span>
<span class="material-symbols-outlined">folder</span>
<span class="material-symbols-outlined">settings</span>
```

### Size Variants

```html
<span class="material-symbols-outlined icon-sm">home</span>   <!-- 18px -->
<span class="material-symbols-outlined icon-md">home</span>   <!-- 24px - default -->
<span class="material-symbols-outlined icon-lg">home</span>   <!-- 32px -->
```

### In Buttons

```html
<button class="btn-primary">
  <span class="material-symbols-outlined">add</span>
  Create New
</button>
```

## Commonly Used Icons in DTK

### Navigation & UI
- `dashboard` - Dashboard/grid view
- `folder` - Projects/folders
- `settings` - Settings/configuration
- `logout` - Logout/sign out
- `menu` - Hamburger menu
- `close` - Close/cancel
- `arrow_back` - Back navigation
- `arrow_forward` - Forward navigation

### File Operations
- `folder_open` - Open folder
- `description` - Document/file
- `upload_file` - Upload
- `download` - Download
- `delete` - Delete/trash
- `edit` - Edit/modify
- `save` - Save
- `print` - Print

### Content Actions
- `add` - Add new item
- `remove` - Remove item
- `search` - Search
- `filter_list` - Filter
- `sort` - Sort
- `more_vert` - More options (vertical)
- `more_horiz` - More options (horizontal)

### Media & Capture
- `photo_camera` - Camera/capture
- `image` - Image/photo
- `collections` - Gallery/collection
- `video_camera_front` - Video camera
- `camera_alt` - Alternative camera icon

### Status & Feedback
- `check_circle` - Success/complete
- `error` - Error
- `warning` - Warning
- `info` - Information
- `help` - Help/support

### Data & Records
- `article` - Article/record
- `book` - Book/publication
- `library_books` - Multiple books
- `inventory` - Inventory
- `archive` - Archive
- `collections_bookmark` - Bookmarked collection

### User & Account
- `person` - Person/user
- `account_circle` - User account
- `group` - Group/multiple users

### Utility
- `refresh` - Refresh/reload
- `sync` - Synchronize
- `visibility` - Show/visible
- `visibility_off` - Hide/invisible
- `lock` - Locked/secure
- `lock_open` - Unlocked

## Icon Browser

To find more icons, browse the full catalog at:
https://fonts.google.com/icons

(Note: Save icon names for offline reference before deploying)

## Examples from DTK

### Sidebar Navigation
```svelte
<span class="material-symbols-outlined sidebar-icon">dashboard</span>
<span class="material-symbols-outlined sidebar-icon">folder</span>
<span class="material-symbols-outlined sidebar-icon">settings</span>
```

### Action Buttons
```svelte
<button class="icon-btn">
  <span class="material-symbols-outlined icon-sm">edit</span>
</button>

<button class="icon-btn danger">
  <span class="material-symbols-outlined icon-sm">delete</span>
</button>
```

### Activity/Status Icons
```svelte
<span class="material-symbols-outlined activity-icon">folder</span>
```

## Font File Location

`/home/pi/dtk/frontend/static/fonts/MaterialSymbolsOutlined.woff2` (3.7MB)

This single font file contains all Material Symbols in the outlined style.
