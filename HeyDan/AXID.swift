enum AXID {
    static let controlsMode = "controls.mode", controlsVoice = "controls.voice",
        controlsOptions = "controls.options", keysCall = "keys.call", optionsWake = "options.wake",
        optionsPauseSends = "options.pauseSends", optionsTyping = "options.typing", pickerTitle = "picker.title",
        pickerClose = "picker.close", pickerSaved = "picker.saved", pickerLive = "picker.live", pickerNext = "picker.next",
        pickerProvider = "picker.provider", pickerModel = "picker.model", pickerVoice = "picker.voice",
        pickerSearch = "picker.search", pickerUseForCall = "picker.useForCall", pickerSave = "picker.save",
        pickerReset = "picker.reset", pickerResult = "picker.result", pickerRetry = "picker.retry"

    static func pickerSample(_ id: String) -> String { "picker.sample.\(id)" }
}
