import ProjectModel
import SourceCorpus

/// Finds the project files that name entry points: Info.plists and other property lists, storyboards, xibs
/// and Xcode projects. The walk is ``SourceDiscovery``'s; only what counts as a project file is deadwood's.
public enum ProjectFileDiscovery {
    /// The project files under `directory`, sorted.
    public static func projectFiles(in directory: String) -> [String] {
        SourceDiscovery.files(under: directory, where: isProjectFile)
    }

    /// Whether `path` names a project file ``projectFiles(in:)`` would list.
    public static func isProjectFile(_ path: String) -> Bool {
        SystemEntryPoints.isProjectFile(path)
    }
}
