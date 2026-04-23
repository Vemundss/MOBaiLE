import Foundation

extension VoiceAgentViewModel {
    var composerSlashCatalog: [ComposerSlashCommand] {
        ComposerSlashCommand.mergedCatalog(backend: backendSlashCommands)
    }

    var composerSlashCommandState: ComposerSlashCommandState? {
        resolveComposerSlashCommandState(from: promptText, commands: composerSlashCatalog)
    }

    func prepareSlashCommand(_ command: ComposerSlashCommand) {
        promptText = command.insertionText
    }

    @discardableResult
    func refreshSlashCommandsFromBackend() async throws -> [ComposerSlashCommand] {
        guard hasConfiguredConnection else {
            backendSlashCommands = []
            throw APIError.missingCredentials
        }
        do {
            let descriptors = try await client.fetchSlashCommands(
                serverURL: normalizedServerURL,
                token: apiToken
            )
            clearConnectionRepairState()
            backendSlashCommands = descriptors.map(ComposerSlashCommand.init(descriptor:))
            return backendSlashCommands
        } catch {
            _ = registerConnectionRepairIfNeeded(from: error)
            throw error
        }
    }

    @discardableResult
    func executeBackendSlashCommand(
        _ command: ComposerSlashCommand,
        arguments: String
    ) async throws -> SlashCommandExecutionResponse {
        guard hasConfiguredConnection else {
            throw APIError.missingCredentials
        }
        do {
            let response = try await client.executeSlashCommand(
                serverURL: normalizedServerURL,
                token: apiToken,
                sessionID: sessionID,
                commandID: command.id,
                arguments: arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : arguments
            )
            clearConnectionRepairState()
            if let sessionContext = response.sessionContext {
                applySessionContext(sessionContext)
            }
            return response
        } catch {
            _ = registerConnectionRepairIfNeeded(from: error)
            throw error
        }
    }
}
