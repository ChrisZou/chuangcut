import Foundation

/// Hard-coded Simplified Chinese copy for V1 (Chris uses Chinese only). SF Symbols stay as symbols.
enum L10n {
    enum App {
        static let name = "ChuangCut"
        static let about = "关于 ChuangCut"
        static let settings = "设置…"
        static let services = "服务"
        static let hide = "隐藏 ChuangCut"
        static let hideOthers = "隐藏其他"
        static let showAll = "显示全部"
        static let quit = "退出 ChuangCut"
    }
    enum Menu {
        static let file = "文件"
        static let edit = "编辑"
        static let view = "显示"
        static let playback = "播放"
        static let clip = "剪辑"
        static let window = "窗口"
        static let help = "帮助"
        static let openMedia = "打开媒体…"
        static let openProject = "打开项目…"
        static let saveProject = "保存项目…"
        static let export = "导出…"
        static let close = "关闭"
        static let undo = "撤销"
        static let redo = "重做"
        static let cut = "剪切"
        static let copy = "拷贝"
        static let paste = "粘贴"
        static let selectAll = "全选"
        static let fullScreen = "进入全屏"
        static let play = "播放"
        static let pause = "暂停"
        static let back5 = "后退 5 秒"
        static let forward5 = "前进 5 秒"
        static let splitAtPlayhead = "在播放头处分割"
        static let removeSelectedClip = "删除所选片段"
        static let deselect = "取消选择"
        static let previewCuts = "预览剪辑"
        static let snapTrim = "吸附修剪边缘"
        static let transcribeAgain = "重新转写…"
        static let detectAgain = "重新检测剪辑点"
        static let minimize = "最小化"
        static let zoom = "缩放"
        static let bringAllFront = "前置全部窗口"
    }
    enum Toolbar {
        static let importMedia = "导入"
        static let export = "导出"
        static let importHelp = "打开视频或音频文件（⌘O）"
        static let exportHelp = "导出成片（⇧⌘E）"
    }
    enum Empty {
        static let dropHint = "拖入视频或音频，或按 ⌘O"
        static let importButton = "导入"
        static let transcriptionDoubao = "转写引擎：豆包 Seed-ASR"
        static let modelPrefix = "模型："
        static let noDoubaoKey = "未设置豆包 API Key — 打开设置"
        static let noModel = "未下载模型 — 去下载"
    }
    enum Player {
        static let play = "播放"
        static let pause = "暂停"
        static let playPause = "播放 / 暂停（空格）"
        static let back5 = "后退 5 秒"
        static let forward5 = "前进 5 秒"
        static let back5Help = "后退 5 秒（←）"
        static let forward5Help = "前进 5 秒（→）"
        static let previewCuts = "预览剪辑"
        static let revealExport = "在访达中显示导出文件"
        static let source = "源素材"
    }
    enum Transcript {
        static let title = "转写稿"
        static let hint = "点击文字定位 · ⌥点击切换剪辑 · 选中后 ⌫ 剪切"
        static let transcribe = "转写"
        static let accessibility =
            "转写稿。点击文字选择片段；选中文字后按删除键剪切。"
        static let toggleCut = "切换剪辑"
        static let cutSelection = "剪切所选"
        static let copy = "拷贝"
    }
    enum Timeline {
        static let title = "时间线"
        static let accessibility =
            "时间线。选择片段或字幕并拖动边缘修剪。删除键移除所选。"
        static let showRemoved = "显示已删除"
        static let split = "分割"
        static let splitHelp = "在播放头处分割片段（⌘B）"
        static let zoom = "时间线缩放"
        static let zoomOut = "缩小"
        static let zoomIn = "放大"
        static let source = "源素材"
        static let edited = "成片"
        static let scrubHelp = "点击或拖动擦洗 · ⌘滚轮缩放"
        static let deleteSubtitle = "删除字幕"
        static let deleteSelectedSubtitle = "删除所选字幕"
        static let removeSelectedClip = "删除所选片段"
        static let clipTooltip = "片段 %d · %.2f–%.2f 秒 · 拖动边缘修剪"
        static let cutTooltip = "%@ · %.2f–%.2f 秒 · ⌥点击切换"
    }
    enum Export {
        static let title = "导出"
        static let chooseOutput = "选择输出文件"
        static let quality = "画质"
        static let compact = "紧凑 · 硬件编码"
        static let balanced = "均衡 · 硬件编码"
        static let high = "高清 · 硬件编码"
        static let software = "H.264 · CRF 20"
        static let subtitleTrack = "字幕轨道"
        static let subtitleTrackHelp = "嵌入可开关的字幕轨道，不烧录进画面"
        static let srt = "导出 SRT 文件"
        static let burn = "烧录字幕"
        static let style = "字幕样式"
        static let cancel = "取消"
        static let export = "导出"
    }
    enum Settings {
        static let transcription = "转写"
        static let detection = "检测"
        static let subtitles = "字幕"
        static let engine = "引擎"
        static let doubao = "豆包 Seed-ASR"
        static let whisper = "Whisper（本机）"
        static let doubaoFooter = "逐字转写，含口误与重复，便于只保留最后一遍。音频会上传至火山引擎。"
        static let whisperFooter = "离线可用，但会整理口语，常漏掉重复片段与语气词。"
        static let apiKey = "API Key"
        static let hotword = "热词表 ID"
        static let hotwordPrompt = "可选"
        static let doubaoSection = "豆包"
        static let getKey = "在火山引擎控制台获取「录音文件识别大模型」密钥"
        static let tools = "工具"
        static let whisperModel = "Whisper 模型"
        static let modelPath = "模型路径"
        static let chooseModel = "选择模型"
        static let installed = "已安装"
        static let chooseAModel = "选择模型"
        static let download = "下载"
        static let cancel = "取消"
        static let downloadFailed = "下载失败"
        static let ok = "好"
        static let findModels = "查找模型（含下载文件夹）"
        static let language = "语言"
        static let auto = "自动"
        static let pauseThreshold = "停顿阈值"
        static let beforeSpeech = "说话前保留"
        static let pauseAfterSentence = "句末停顿"
        static let pauseAfterComma = "逗号后停顿"
        static let pauseBetweenWords = "词间停顿"
        static let fillers = "语气词"
        static let replacePunct = "将句内标点替换为空格"
        static let font = "字体"
        static let size = "字号"
        static let colorHex = "颜色（十六进制）"
        static let outline = "描边"
        static let bottomMargin = "底边距"
        static let cjkLine = "中文每行字数：%d"
        static let latinLine = "西文每行字数：%d"
    }
    enum Alert {
        static let transcribeAgain = "重新转写？"
        static let transcribeAgainBody =
            "检测到的剪辑点及其修剪会被新的分析替换。手动剪辑与分割会保留，可用 ⌘Z 撤销。"
        static let transcribe = "转写"
        static let cancel = "取消"
        static let ok = "好"
        static let mediaMissing = "找不到源媒体文件：%@"
        static let mediaMissingTitle = "媒体缺失"
    }
    enum Stage {
        static let opening = "正在打开"
        static let openingProject = "正在打开项目"
        static let transcribing = "正在转写"
        static let exporting = "正在导出"
        static let detecting = "正在检测剪辑点"
        static let extracting = "正在提取音频"
        static let cached = "使用缓存转写"
        static let ready = "就绪"
        static let saving = "正在保存"
        static func map(_ english: String) -> String {
            switch english {
            case "Transcribing": return transcribing
            case "Extracting audio": return extracting
            case "Cached transcript": return cached
            case "Detecting cuts": return detecting
            case "Ready": return ready
            case "Opening": return opening
            case "Exporting": return exporting
            default: return english
            }
        }
    }
    enum Undo {
        static let transcribe = "转写"
        static let detect = "检测剪辑点"
        static let toggleCut = "切换剪辑"
        static let toggleGroup = "切换分组"
        static let manualCut = "手动剪切"
        static let trim = "修剪片段"
        static let adjustSubtitle = "调整字幕时间"
        static let deleteSubtitle = "删除字幕"
        static let removeClip = "删除片段"
        static let split = "分割片段"
    }
    enum CutKind {
        static let pause = "停顿"
        static let filler = "语气词"
        static let retake = "重说"
        static let manual = "手动"
    }
    enum Processing {
        static let cancel = "取消"
        static let cancelAccessibility = "取消处理"
    }
    enum Window {
        static let editedSuffix = "%@ 成片"
        static let dirtyMark = "● "
    }
}
