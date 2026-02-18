---
applyTo: "frontend/**"
---

# Icons

## Rules

- **Always use Material Symbols Outlined** for every icon in the application. Do not use SVGs, emoji, Unicode symbols, Heroicons, FontAwesome, Lucide, or any other icon system.
- **Never install additional icon libraries.** The font is already bundled at `frontend/static/fonts/MaterialSymbolsOutlined.woff2` and loaded in `frontend/static/app.css`.
- **Never render icons as images** (`<img>`, `<svg>`, background-image). Always use the font span pattern below.

## Required Markup Pattern

Every icon must follow this exact structure — a `<span>` with class `material-symbols-outlined`, containing only the icon name as text:

```svelte
<span class="material-symbols-outlined">home</span>
```

Size is controlled by adding one of three modifier classes (default is `icon-md`):

```svelte
<span class="material-symbols-outlined icon-sm">home</span>   <!-- 18px -->
<span class="material-symbols-outlined icon-md">home</span>   <!-- 24px -->
<span class="material-symbols-outlined icon-lg">home</span>   <!-- 32px -->
```

Do not set font-size on icon spans directly — use the modifier classes.

## Icons Inside Buttons

Place the span as the first child, followed by the label text:

```svelte
<button class="btn-primary">
  <span class="material-symbols-outlined icon-sm">add</span>
  Create New
</button>

<button class="icon-btn">
  <span class="material-symbols-outlined icon-sm">edit</span>
</button>
```

## Choosing an Icon Name

Pick from the list below. If the right icon isn't here, check https://fonts.google.com/icons (offline deployments: verify the name is in the woff2 before using).

### Navigation & UI
| Name | Use for |
|---|---|
| `dashboard` | Dashboard / grid view |
| `folder` | Projects / folders |
| `settings` | Settings / configuration |
| `logout` | Sign out |
| `menu` | Hamburger menu |
| `close` | Close / cancel |
| `arrow_back` | Back navigation |
| `arrow_forward` | Forward navigation |

### File Operations
| Name | Use for |
|---|---|
| `folder_open` | Open folder |
| `description` | Document / file |
| `upload_file` | Upload |
| `download` | Download |
| `delete` | Delete / trash |
| `edit` | Edit / modify |
| `save` | Save |
| `print` | Print |

### Content Actions
| Name | Use for |
|---|---|
| `add` | Add new item |
| `remove` | Remove item |
| `search` | Search |
| `filter_list` | Filter |
| `sort` | Sort |
| `more_vert` | More options (vertical) |
| `more_horiz` | More options (horizontal) |

### Media & Capture
| Name | Use for |
|---|---|
| `photo_camera` | Camera / capture |
| `image` | Image / photo |
| `collections` | Gallery / collection |
| `video_camera_front` | Video camera |
| `camera_alt` | Alternative camera |

### Status & Feedback
| Name | Use for |
|---|---|
| `check_circle` | Success / complete |
| `error` | Error |
| `warning` | Warning |
| `info` | Information |
| `help` | Help / support |

### Data & Records
| Name | Use for |
|---|---|
| `article` | Article / record |
| `book` | Book / publication |
| `library_books` | Multiple books |
| `inventory` | Inventory |
| `archive` | Archive |
| `collections_bookmark` | Bookmarked collection |

### User & Account
| Name | Use for |
|---|---|
| `person` | Person / user |
| `account_circle` | User account |
| `group` | Group / multiple users |

### Utility
| Name | Use for |
|---|---|
| `refresh` | Refresh / reload |
| `sync` | Synchronize |
| `visibility` | Show / visible |
| `visibility_off` | Hide / invisible |
| `lock` | Locked / secure |
| `lock_open` | Unlocked |
