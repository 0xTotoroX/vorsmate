// [INPUT]: 运行中的 Apple Music、用户触发的自动化操作和一次性工作目录。
// [OUTPUT]: 当前播放或选中歌曲的元数据与未转码的原始封面。
// [POS]: VorsmateSystem 的 Apple Events 边界，仅在执行收藏时读取 Music。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MusicCoverArtwork: Sendable {
    let file: URL
    let track: String
    let artist: String
    let album: String
}

enum MusicCoverReader {
    static func read(in directory: URL) async throws -> MusicCoverArtwork {
        let isRunning = await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
        }
        guard isRunning else { throw MusicCoverError.musicNotRunning }

        let raw = directory.appending(path: "artwork")
        let metadata = directory.appending(path: "track.plist")
        let result = try await LocalToolProcess.run(
            URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script, raw.path, metadata.path])
        guard result.status == 0 else {
            if result.output.contains("(-1743)") { throw MusicCoverError.musicPermissionRequired }
            if result.output.contains("(1002)") { throw MusicCoverError.noTrack }
            if result.output.contains("(1003)") { throw MusicCoverError.noArtwork }
            throw MusicCoverError.musicReadFailed
        }

        let tags = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: metadata))
        guard let image = CGImageSourceCreateWithURL(raw as CFURL, nil),
            CGImageSourceGetCount(image) > 0, let kind = CGImageSourceGetType(image),
            let fileExtension = UTType(kind as String)?.preferredFilenameExtension
        else { throw MusicCoverError.noArtwork }
        let file = raw.appendingPathExtension(fileExtension)
        try FileManager.default.moveItem(at: raw, to: file)
        return MusicCoverArtwork(
            file: file, track: tags["track"] ?? "", artist: tags["artist"] ?? "", album: tags["album"] ?? "")
    }

    // Store metadata as a plist so newlines and Unicode in track names survive intact.
    static let script = """
        use framework "Foundation"
        use scripting additions

        on run argv
            set imagePath to item 1 of argv
            set metadataPath to item 2 of argv
            tell application id "com.apple.Music"
                set targetTrack to missing value
                if player state is playing or player state is paused then
                    try
                        set targetTrack to current track
                    end try
                end if
                if targetTrack is missing value then
                    try
                        set selectedTracks to selection
                        if selectedTracks is not {} then set targetTrack to item 1 of selectedTracks
                    end try
                end if
                if targetTrack is missing value then error "No track" number 1002
                set trackName to ""
                set trackArtist to ""
                set trackAlbum to ""
                try
                    set trackName to name of targetTrack as text
                end try
                try
                    set trackArtist to artist of targetTrack as text
                end try
                try
                    set trackAlbum to album of targetTrack as text
                end try
                if (count of artworks of targetTrack) is 0 then error "No artwork" number 1003
                set artworkData to raw data of artwork 1 of targetTrack
            end tell

            set imageFile to POSIX file imagePath
            set fileRef to open for access imageFile with write permission
            try
                write artworkData to fileRef
                close access fileRef
            on error errMsg number errNum
                try
                    close access fileRef
                end try
                error errMsg number errNum
            end try
            set fields to current application's NSDictionary's dictionaryWithObjects:{trackName, trackArtist, trackAlbum} forKeys:{"track", "artist", "album"}
            if not (fields's writeToFile:metadataPath atomically:true) then error "Could not write track metadata"
        end run
        """
}
