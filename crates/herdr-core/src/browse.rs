//! A read-only file browser below the login's home directory (#259):
//! directories sorted for the apps, and the start of a file as text, image
//! or neither. Reads through [`Connection::list_dir`] and
//! [`Connection::read_file_head`], so over SSH it needs SFTP like uploads.

use herdr_transport::{Connection, TransportError};

/// Most bytes of a text file the apps show.
pub const MAX_TEXT_BYTES: u64 = 1024 * 1024;
/// Images up to this size open as images; larger ones like other binaries.
pub const MAX_IMAGE_BYTES: u64 = 10 * 1024 * 1024;
/// A NUL byte in this many first bytes makes a file binary.
const BINARY_PROBE: usize = 8192;

const IMAGE_EXTENSIONS: &[&str] = &[
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
];

/// A directory with real, absolute paths.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Directory {
    pub home: String,
    pub path: String,
    /// Directories first, then by name without regard to case.
    pub entries: Vec<DirectoryEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectoryEntry {
    pub name: String,
    /// Absolute, in the listed directory.
    pub path: String,
    pub kind: EntryKind,
    pub size: u64,
    /// Seconds since 1970, 0 if unknown.
    pub modified: u64,
    /// A dot file, `node_modules` or `target`: folded away by default.
    pub hidden: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    Directory,
    File,
    /// A broken link, a socket, a device and the like: not opened.
    Other,
}

/// A file to show on the device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilePreview {
    /// The real, absolute path.
    pub path: String,
    pub name: String,
    pub size: u64,
    /// Seconds since 1970, 0 if unknown.
    pub modified: u64,
    pub content: FileContent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FileContent {
    /// Up to [`MAX_TEXT_BYTES`]; `truncated` when the file is longer.
    Text { text: String, truncated: bool },
    /// The whole image file.
    Image { data: Vec<u8> },
    /// Neither: only size and type are shown.
    Binary,
}

/// The directory at the absolute `path`, empty for the home directory.
pub async fn list(conn: &Connection, path: &str) -> Result<Directory, TransportError> {
    let listing = conn.list_dir(path).await?;
    let mut entries: Vec<DirectoryEntry> = listing
        .entries
        .into_iter()
        .map(|entry| DirectoryEntry {
            path: format!("{}/{}", listing.path.trim_end_matches('/'), entry.name),
            hidden: is_hidden(&entry.name),
            kind: match entry.kind {
                herdr_transport::EntryKind::Dir => EntryKind::Directory,
                herdr_transport::EntryKind::File => EntryKind::File,
                herdr_transport::EntryKind::Other => EntryKind::Other,
            },
            name: entry.name,
            size: entry.size,
            modified: entry.modified,
        })
        .collect();
    sort(&mut entries);
    Ok(Directory {
        home: listing.home,
        path: listing.path,
        entries,
    })
}

/// The file at the absolute `path`: an image up to [`MAX_IMAGE_BYTES`]
/// whole, anything else up to [`MAX_TEXT_BYTES`] (one more to tell it was
/// longer); too large images not at all.
pub async fn preview(conn: &Connection, path: &str) -> Result<FilePreview, TransportError> {
    let name = path.rsplit('/').next().unwrap_or(path).to_owned();
    let image = is_image(&name);
    let head = conn
        .read_file_head(path, |size| {
            if !image {
                MAX_TEXT_BYTES + 1
            } else if size <= MAX_IMAGE_BYTES {
                size
            } else {
                0
            }
        })
        .await?;
    // By the requested name, as the read above: a link `shot` to
    // `photo.png` was read as text.
    let content = classify(&name, head.size, head.data);
    let name = head.path.rsplit('/').next().unwrap_or(&name).to_owned();
    Ok(FilePreview {
        content,
        path: head.path,
        name,
        size: head.size,
        modified: head.modified,
    })
}

/// What `data`, the start of the file `name` of `size` bytes, shows as.
pub fn classify(name: &str, size: u64, mut data: Vec<u8>) -> FileContent {
    if is_image(name) {
        return if size <= MAX_IMAGE_BYTES {
            FileContent::Image { data }
        } else {
            FileContent::Binary
        };
    }
    if data[..data.len().min(BINARY_PROBE)].contains(&0) {
        return FileContent::Binary;
    }
    let truncated = data.len() as u64 > MAX_TEXT_BYTES;
    if truncated {
        // Up to the last complete line.
        data.truncate(MAX_TEXT_BYTES as usize);
        if let Some(end) = data.iter().rposition(|byte| *byte == b'\n') {
            data.truncate(end + 1);
        }
    }
    FileContent::Text {
        text: String::from_utf8_lossy(&data).into_owned(),
        truncated,
    }
}

fn is_image(name: &str) -> bool {
    name.rsplit_once('.').is_some_and(|(_, ext)| {
        IMAGE_EXTENSIONS
            .iter()
            .any(|known| known.eq_ignore_ascii_case(ext))
    })
}

fn is_hidden(name: &str) -> bool {
    name.starts_with('.') || name == "node_modules" || name == "target"
}

fn sort(entries: &mut [DirectoryEntry]) {
    entries.sort_by(|a, b| {
        (a.kind != EntryKind::Directory)
            .cmp(&(b.kind != EntryKind::Directory))
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            .then_with(|| a.name.cmp(&b.name))
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, kind: EntryKind) -> DirectoryEntry {
        DirectoryEntry {
            name: name.into(),
            path: format!("/home/a/{name}"),
            kind,
            size: 0,
            modified: 0,
            hidden: is_hidden(name),
        }
    }

    #[test]
    fn sorts_directories_first_then_by_name() {
        let mut entries = vec![
            entry("b.txt", EntryKind::File),
            entry("Zeta", EntryKind::Directory),
            entry("A.md", EntryKind::File),
            entry("alpha", EntryKind::Directory),
            entry("link", EntryKind::Other),
        ];
        sort(&mut entries);
        let names: Vec<_> = entries.iter().map(|entry| entry.name.as_str()).collect();
        assert_eq!(names, ["alpha", "Zeta", "A.md", "b.txt", "link"]);
    }

    #[test]
    fn hides_dot_files_and_build_output() {
        assert!(is_hidden(".git"));
        assert!(is_hidden(".env"));
        assert!(is_hidden("node_modules"));
        assert!(is_hidden("target"));
        assert!(!is_hidden("src"));
        assert!(!is_hidden("targets"));
    }

    #[test]
    fn reads_text() {
        assert_eq!(
            classify("notes.md", 6, b"hello\n".to_vec()),
            FileContent::Text {
                text: "hello\n".into(),
                truncated: false
            }
        );
    }

    #[test]
    fn cuts_long_text_at_a_line() {
        let mut data = vec![b'a'; MAX_TEXT_BYTES as usize - 10];
        data.push(b'\n');
        data.extend(vec![b'b'; 100]);
        let FileContent::Text { text, truncated } = classify("big.log", 5_000_000, data) else {
            panic!("not text");
        };
        assert!(truncated);
        assert_eq!(text.len(), MAX_TEXT_BYTES as usize - 9);
        assert!(text.ends_with('\n'));
    }

    #[test]
    fn nul_bytes_mean_binary() {
        assert_eq!(
            classify("app", 4, vec![0x7f, b'E', 0, 1]),
            FileContent::Binary
        );
    }

    #[test]
    fn images_open_up_to_their_limit() {
        assert_eq!(
            classify("Shot.PNG", 3, vec![1, 2, 3]),
            FileContent::Image {
                data: vec![1, 2, 3]
            }
        );
        assert_eq!(
            classify("huge.jpg", MAX_IMAGE_BYTES + 1, Vec::new()),
            FileContent::Binary
        );
    }
}
