enum AXID {
    static let optionsVoice = "options.voice",
        controlsOptions = "controls.options", keysCall = "keys.call",
        optionsTyping = "options.typing", pickerTitle = "picker.title",
        pickerClose = "picker.close", pickerSaved = "picker.saved", pickerLive = "picker.live", pickerNext = "picker.next",
        pickerProvider = "picker.provider", pickerModel = "picker.model", pickerVoice = "picker.voice",
        pickerSearch = "picker.search", pickerUseForCall = "picker.useForCall", pickerSave = "picker.save",
        pickerReset = "picker.reset", pickerResult = "picker.result", pickerRetry = "picker.retry",
        pickerNameRetry = "picker.nameRetry", pickerFilter = "picker.filter"

    static func pickerSample(_ id: String) -> String { "picker.sample.\(id)" }
}
