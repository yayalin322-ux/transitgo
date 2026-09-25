import AppIntents
import Foundation

/// "嘿 Siri，臺北站下一班南下列車" — answered from the backend's station board, read aloud without opening the app.
struct NextTrainIntent: AppIntent {
    static var title: LocalizedStringResource { "下一班台鐵列車" }
    static var description: IntentDescription {
        IntentDescription("查某個台鐵車站下一班北上或南下的列車：幾點開、開往哪裡、有沒有誤點。")
    }

    @Parameter(title: "車站", requestValueDialog: "哪一個車站？")
    var station: TRAStationEntity

    @Parameter(title: "方向", default: .south, requestValueDialog: "北上還是南下？")
    var direction: TrainHeadingOption

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$station)下一班\(\.$direction)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let board = try await RailBoardService.board(stationID: station.id)
            let text = board.spoken(heading: direction.heading, at: Date())
            return .result(dialog: IntentDialog(stringLiteral: text))
        } catch {
            return .result(dialog: "現在連不上列車資料，請稍後再試。")
        }
    }
}
