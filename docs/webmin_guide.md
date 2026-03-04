# Webmin Samba Share Guide

This manual guides you through creating different types of file shares using the Webmin interface (`https://<IP>:10000`).

## 🔑 Permissions Cheat Sheet
When creating a directory, use these **Octal Codes** in the *"Create with permissions"* field:

| Code | Type | Meaning | Used For |
| :--- | :--- | :--- | :--- |
| **700** | **Private** | Owner has full access. **Nobody else** can read/write. | Personal Folders |
| **770** | **Group** | Owner and **Group** have full access. Others blocked. | Team/Department Shares |
| **755** | **Read-Only** | Owner writes. Everyone else can **Read** only. | Public Dropboxes (View Only) |
| **777** | **Public** | **Everyone** can Read, Write, and Execute. | Guest/Open Shares |

---

## 🏗️ Step 1: Create the Share (Common Steps)

1.  Login to Webmin.
2.  Navigate to **Servers** > **Samba Windows File Sharing**.
3.  Click **Create a new file share**.

---

## 🔒 Scenario 1: Private Personal Folder
*Accessible ONLY by you.*

### Part A: creation
*   **Share name**: `myshare_private` (Example)
*   **Directory to share**: `/srv/samba/private/username`
*   **Automatically create directory**: **Yes**
*   **Create with owner**: `<your_username>`
*   **Create with group**: `<your_username>`
*   **Create with permissions**: **700**
*   **Click Create**.

### Part B: Access Control
*   Click on the new share.
*   Go to **Security and Access Control**.
*   **Writable**: Yes
*   **Guest Access**: None
*   **Valid Users**: `<your_username>`
*   **Save**.

### Part C: File Permission Options (Crucial)
*   Go to **File Permission Options**.
*   **New Unix file mode**: `600` (Files are private)
*   **New Unix directory mode**: `700` (Folders are private)
*   **Force Unix user**: `<your_username>`
*   **Save**.

---

## 👥 Scenario 2: Private Group Share
*Accessible by a specific team (e.g. `editors`).*

### Part A: Creation
*   **Share name**: `team_projects`
*   **Directory to share**: `/srv/samba/team`
*   **Automatically create directory**: **Yes**
*   **Create with owner**: `<main_user>`
*   **Create with group**: `<group_name>` (e.g. `editors`)
*   **Create with permissions**: **770**
*   **Click Create**.

### Part B: Access Control
*   Click on the share.
*   Go to **Security and Access Control**.
*   **Writable**: Yes
*   **Guest Access**: None
*   **Valid Users**: `@<group_name>` (or list users: `user1 user2`)
*   **Save**.

### Part C: File Permission Options
*   Go to **File Permission Options**.
*   **New Unix file mode**: `660` (Group can write)
*   **New Unix directory mode**: `770` (Group can enter)
*   **Force Unix group**: `<group_name>`
*   **Save**.

---

## 🌍 Scenario 3: Public Guest Share (Open)
*Everyone on network can Read/Write without password.*

### Part A: Creation
*   **Share name**: `public_drop`
*   **Directory to share**: `/srv/samba/public`
*   **Automatically create directory**: **Yes**
*   **Create with owner**: `nobody` (Standard "Guest" account)
*   **Create with group**: `nogroup`
*   **Create with permissions**: **777**
*   **Click Create**.

> **Why `nobody`?**
> Sames maps "Guest" users to the Linux user `nobody` by default. If you make a specific user the owner (e.g. `visnu`), guests might get "Permission Denied" errors unless you are very careful with the `777` permissions. using `nobody` is safest for public folders.

### Part B: Access Control
*   Click on the share.
*   Go to **Security and Access Control**.
*   **Writable**: Yes
*   **Guest Access**: **Yes** (or Guest only)
*   **Guest Unix User**: `nobody`
*   **Save**.

### Part C: File Permission Options
*   Go to **File Permission Options**.
*   **New Unix file mode**: `666` (Everyone read/write)
*   **New Unix directory mode**: `777`
*   **Force Unix user**: `nobody`
*   **Save**.

---

## 🔄 Final Step: Restart Samba
1.  Go back to the main **Samba Windows File Sharing** page.
2.  Click **Restart Samba Servers** to apply changes.
