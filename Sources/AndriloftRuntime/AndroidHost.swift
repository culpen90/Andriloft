import AppKit
import AndriloftCore

/// Maps a small Android framework surface to AppKit. No SDK, device or guest OS is involved.
public final class AndroidHost: DexHost {
    public weak var window: NSWindow?
    public weak var virtualMachine: DexVM?
    public var onMessage: ((String) -> Void)?
    public var onFailure: ((Error) -> Void)?
    public private(set) var contentView: NSView?
    public private(set) var invocationCount = 0
    public private(set) var failure: Error?
    public var applicationObject: DexObject?
    public private(set) var isFinished = false
    public var onFinish: (() -> Void)?
    public let resourceStrings: [UInt32: String]
    private var views: [UUID: NSView] = [:]
    private var actions: [UUID: AndroidButtonAction] = [:]
    private var preferences: [String: UserDefaults] = [:]
    private let packageName: String

    public init(packageName: String, strings: [UInt32: String] = [:]) {
        self.packageName = packageName
        resourceStrings = strings
    }

    public static func preferenceSuiteName(packageName: String, name: String) -> String {
        func encode(_ text: String) -> String { text.utf8.map { String(format: "%02x", $0) }.joined() }
        return "dev.andriloft.guest.\(encode(packageName)).\(encode(name))"
    }

    public func view(for object: DexObject) -> NSView? { views[object.id] }

    public func invoke(method: DexMethodReference, receiver: DexValue?, arguments: [DexValue], vm: DexVM) throws -> DexValue {
        invocationCount += 1
        let owner = method.owner
        let name = method.name
        let object = receiver?.objectValue
        for argument in arguments {
            if case .string(let text) = argument, text.utf8.count > 1_048_576 { throw DexError.limit("Framework string argument exceeds 1 MiB") }
        }
        func arg(_ index: Int) throws -> DexValue {
            guard arguments.indices.contains(index) else { throw AndroidRuntimeError.invalidArgument("Missing argument for \(owner).\(name)") }
            return arguments[index]
        }
        func requireObject() throws -> DexObject {
            guard let object else { throw AndroidRuntimeError.invalidArgument("Null receiver for \(owner).\(name)") }
            return object
        }
        func resourceText(_ value: DexValue) throws -> String {
            if case .int(let id) = value {
                guard let string = resourceStrings[UInt32(bitPattern: id)] else {
                    throw AndroidRuntimeError.invalidArgument("String resource \(String(format: "0x%08x", id)) could not be resolved.")
                }
                return string
            }
            return value.text
        }

        if owner == "Ljava/lang/Object;" {
            switch name {
            case "<init>": return .null
            case "toString": return .string(receiver?.text ?? "null")
            case "equals":
                let other = try arg(0)
                return .int(object != nil && object?.id == other.objectValue?.id ? 1 : 0)
            case "hashCode": return .int(Int32(truncatingIfNeeded: object?.id.hashValue ?? 0))
            default: break
            }
        }
        if owner == "Ljava/lang/StringBuilder;" || owner == "Ljava/lang/StringBuffer;" {
            let target = try requireObject()
            switch name {
            case "<init>":
                target.fields["nativeText"] = .string(arguments.first.map { if case .string(let text) = $0 { return text }; return "" } ?? "")
                return .null
            case "append":
                let value = try arg(0)
                let text: String
                if method.descriptor.hasPrefix("(Z") { text = value.intValue == 0 ? "false" : "true" }
                else if method.descriptor.hasPrefix("(C"), let scalar = UnicodeScalar(UInt32(bitPattern: value.intValue)) { text = String(scalar) }
                else { text = value.text }
                let existing = target.fields["nativeText"]?.text ?? ""
                guard existing.utf8.count <= 1_048_576 - min(text.utf8.count, 1_048_577) else { throw DexError.limit("StringBuilder exceeds 1 MiB") }
                target.fields["nativeText"] = .string(existing + text)
                return .object(target)
            case "toString": return target.fields["nativeText"] ?? .string("")
            case "length": return .int(Int32((target.fields["nativeText"]?.text ?? "").utf16.count))
            default: break
            }
        }
        if owner == "Ljava/lang/String;" || owner == "Ljava/lang/CharSequence;" || owner == "Landroid/text/Editable;" {
            let text = receiver?.text ?? ""
            switch name {
            case "toString": return .string(text)
            case "valueOf":
                let value = try arg(0)
                if method.descriptor.hasPrefix("(Z") { return .string(value.intValue == 0 ? "false" : "true") }
                return .string(value.text)
            case "length": return .int(Int32(text.utf16.count))
            case "isEmpty": return .int(text.isEmpty ? 1 : 0)
            case "equals", "contentEquals":
                if case .string(let other) = try arg(0) { return .int(text == other ? 1 : 0) }
                return .int(0)
            case "hashCode":
                let result = text.utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) }
                return .int(result)
            case "concat":
                let other = try arg(0).text
                guard text.utf8.count <= 1_048_576 - min(other.utf8.count, 1_048_577) else { throw DexError.limit("String exceeds 1 MiB") }
                return .string(text + other)
            case "trim": return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case "toUpperCase": return .string(text.uppercased())
            case "toLowerCase": return .string(text.lowercased())
            default: break
            }
        }
        if owner == "Ljava/lang/Integer;" {
            switch name {
            case "toString": return .string((try arg(0)).text)
            case "parseInt":
                guard let value = Int32((try arg(0)).text) else { throw AndroidRuntimeError.invalidArgument("Invalid integer") }
                return .int(value)
            default: break
            }
        }
        if owner == "Ljava/lang/Math;" {
            let left = try arg(0).intValue
            switch name {
            case "abs" where method.descriptor == "(I)I": return .int(left == Int32.min ? left : abs(left))
            case "min" where method.descriptor == "(II)I": return .int(min(left, try arg(1).intValue))
            case "max" where method.descriptor == "(II)I": return .int(max(left, try arg(1).intValue))
            default: break
            }
        }
        if owner == "Landroid/util/Log;", ["d", "i", "w", "e", "v"].contains(name) {
            onMessage?("\(try arg(0).text): \(try arg(1).text)")
            return .int(0)
        }
        if owner == "Landroid/graphics/Color;" {
            if name == "rgb" {
                let r = try arg(0).intValue & 255, g = try arg(1).intValue & 255, b = try arg(2).intValue & 255
                return .int(Int32(bitPattern: 0xff000000) | r << 16 | g << 8 | b)
            }
            if name == "argb" {
                return .int((try arg(0).intValue & 255) << 24 | (try arg(1).intValue & 255) << 16 | (try arg(2).intValue & 255) << 8 | (try arg(3).intValue & 255))
            }
        }
        if owner == "Landroid/widget/Toast;" {
            if name == "makeText" {
                let toast = DexObject(type: owner)
                toast.fields["nativeText"] = .string(try resourceText(arg(1)))
                return .object(toast)
            }
            if name == "show" { onMessage?(object?.fields["nativeText"]?.text ?? ""); return .null }
            if name == "cancel" { return .null }
        }
        if ["Landroid/app/Activity;", "Landroid/app/Application;", "Landroid/content/Context;", "Landroid/content/ContextWrapper;", "Landroid/view/ContextThemeWrapper;"].contains(owner) {
            switch name {
            case "<init>", "onCreate", "onStart", "onResume", "onPause", "onStop", "onDestroy": return .null
            case "setContentView":
                guard method.descriptor.hasPrefix("(Landroid/view/View;"), let target = try arg(0).objectValue, let view = views[target.id] else {
                    throw AndroidRuntimeError.unsupportedAPI("Activity.setContentView(int): XML layout inflation is not implemented. Use programmatic views.")
                }
                contentView = view
                if let window { attach(view, to: window) }
                return .null
            case "setTitle": window?.title = try resourceText(arg(0)); return .null
            case "getString", "getText": return .string(try resourceText(arg(0)))
            case "getApplication", "getApplicationContext": return applicationObject.map(DexValue.object) ?? receiver ?? .null
            case "getBaseContext": return receiver ?? .null
            case "getPackageName": return .string(packageName)
            case "getSharedPreferences":
                let key = try arg(0).text
                guard key.utf8.count <= 128, packageName.utf8.count <= 255 else {
                    throw AndroidRuntimeError.invalidArgument("Unsupported preference store name")
                }
                let target = DexObject(type: "Landroid/content/SharedPreferences;")
                guard preferences[key] != nil || preferences.count < 128 else { throw DexError.limit("Too many guest preference stores") }
                guard let suite = preferences[key] ?? UserDefaults(suiteName: Self.preferenceSuiteName(packageName: packageName, name: key)) else {
                    throw AndroidRuntimeError.invalidArgument("Could not open the guest preference store")
                }
                preferences[key] = suite
                target.fields["nativePreferenceName"] = .string(key)
                return .object(target)
            case "finish":
                isFinished = true
                DispatchQueue.main.async { [weak self] in self?.onFinish?() }
                return .null
            case "runOnUiThread":
                if let runnable = try arg(0).objectValue {
                    _ = try vm.invoke(receiver: runnable, name: "run", descriptor: "()V", arguments: [])
                }
                return .null
            default: break
            }
        }
        if owner == "Landroid/content/SharedPreferences;" || owner == "Landroid/content/SharedPreferences$Editor;" {
            let target = try requireObject()
            guard let storeName = target.fields["nativePreferenceName"]?.text, let suite = preferences[storeName] else { throw AndroidRuntimeError.invalidArgument("Missing preference store") }
            switch name {
            case "edit":
                let editor = DexObject(type: "Landroid/content/SharedPreferences$Editor;")
                editor.fields["nativePreferenceName"] = .string(storeName)
                return .object(editor)
            case "getInt": let key = try arg(0).text; return .int(suite.object(forKey: key) == nil ? try arg(1).intValue : Int32(truncatingIfNeeded: suite.integer(forKey: key)))
            case "getBoolean": let key = try arg(0).text; return .int(suite.object(forKey: key) == nil ? try arg(1).intValue : suite.bool(forKey: key) ? 1 : 0)
            case "getString":
                if let text = suite.string(forKey: try arg(0).text) { return .string(text) }
                return try arg(1)
            case "contains": return .int(suite.object(forKey: try arg(0).text) == nil ? 0 : 1)
            case "putInt", "putBoolean", "putString":
                let key = try arg(0).text, value = try arg(1)
                guard key.utf8.count <= 512, target.fields.count < 4096 else { throw DexError.limit("Guest preference editor exceeds its limit") }
                target.fields["pending:\(key)"] = value
                return .object(target)
            case "apply", "commit":
                for (key, value) in target.fields where key.hasPrefix("pending:") {
                    let destination = String(key.dropFirst(8))
                    if case .null = value { suite.removeObject(forKey: destination) }
                    else if case .string(let text) = value { suite.set(text, forKey: destination) }
                    else { suite.set(Int(value.intValue), forKey: destination) }
                }
                target.fields = ["nativePreferenceName": .string(storeName)]
                return name == "commit" ? .int(1) : .null
            default: break
            }
        }
        if owner.hasPrefix("Landroid/widget/") || owner.hasPrefix("Landroid/view/") {
            if name == "<init>" {
                let target = try requireObject()
                guard views.count < 4096 else { throw DexError.limit("Activity exceeds 4096 native views") }
                switch owner {
                case "Landroid/widget/LinearLayout;":
                    let stack = NSStackView()
                    stack.orientation = .horizontal
                    stack.alignment = .leading
                    stack.distribution = .fill
                    stack.spacing = 12
                    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
                    views[target.id] = stack
                case "Landroid/widget/TextView;":
                    let text = NSTextField(wrappingLabelWithString: "")
                    text.font = .systemFont(ofSize: 15)
                    text.textColor = .labelColor
                    text.setContentHuggingPriority(.required, for: .vertical)
                    views[target.id] = text
                case "Landroid/widget/EditText;":
                    let text = NSTextField(string: "")
                    text.placeholderString = ""
                    text.font = .systemFont(ofSize: 15)
                    text.bezelStyle = .roundedBezel
                    views[target.id] = text
                case "Landroid/widget/Button;":
                    let button = NSButton(title: "", target: nil, action: nil)
                    button.bezelStyle = .rounded
                    button.controlSize = .large
                    button.font = .systemFont(ofSize: 15, weight: .medium)
                    views[target.id] = button
                case "Landroid/view/ViewGroup$LayoutParams;", "Landroid/widget/LinearLayout$LayoutParams;":
                    if arguments.count >= 2 { target.fields["width"] = arguments[0]; target.fields["height"] = arguments[1] }
                    return .null
                default: throw AndroidRuntimeError.unsupportedAPI("\(owner)->\(name)\(method.descriptor)")
                }
                return .null
            }
            let target = try requireObject()
            guard let view = views[target.id] else { throw AndroidRuntimeError.missingObject(target.type) }
            switch name {
            case "setOrientation":
                guard let stack = view as? NSStackView else { throw AndroidRuntimeError.invalidArgument("setOrientation requires LinearLayout") }
                stack.orientation = try arg(0).intValue == 1 ? .vertical : .horizontal
                stack.alignment = stack.orientation == .vertical ? .leading : .centerY
                return .null
            case "addView":
                guard let stack = view as? NSStackView, let child = try arg(0).objectValue, let childView = views[child.id] else { throw AndroidRuntimeError.invalidArgument("addView requires a supported layout and child view") }
                guard childView.superview == nil, childView !== stack else { throw AndroidRuntimeError.invalidArgument("A child view must have only one parent") }
                stack.addArrangedSubview(childView)
                if stack.orientation == .vertical {
                    childView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)).isActive = true
                }
                return .null
            case "setText":
                let text = try resourceText(arg(0))
                if let field = view as? NSTextField { field.stringValue = text }
                else if let button = view as? NSButton { button.title = text }
                else { throw AndroidRuntimeError.invalidArgument("setText requires a text control") }
                return .null
            case "getText":
                if let field = view as? NSTextField { return .string(field.stringValue) }
                if let button = view as? NSButton { return .string(button.title) }
                return .string("")
            case "setHint": (view as? NSTextField)?.placeholderString = try resourceText(arg(0)); return .null
            case "setTextSize":
                let size = try arg(arguments.count - 1).numericFloat
                guard size.isFinite, size > 0, size < 500 else { throw AndroidRuntimeError.invalidArgument("Invalid text size") }
                (view as? NSControl)?.font = .systemFont(ofSize: size)
                return .null
            case "setTextColor": (view as? NSTextField)?.textColor = color(try arg(0).intValue); return .null
            case "setBackgroundColor":
                view.wantsLayer = true
                view.layer?.backgroundColor = color(try arg(0).intValue).cgColor
                return .null
            case "setPadding":
                let left = CGFloat(try arg(0).intValue), top = CGFloat(try arg(1).intValue), right = CGFloat(try arg(2).intValue), bottom = CGFloat(try arg(3).intValue)
                if let stack = view as? NSStackView { stack.edgeInsets = NSEdgeInsets(top: max(0, top), left: max(0, left), bottom: max(0, bottom), right: max(0, right)) }
                return .null
            case "setGravity":
                let gravity = try arg(0).intValue & 7
                (view as? NSTextField)?.alignment = gravity == 1 ? .center : gravity == 5 ? .right : .left
                return .null
            case "setEnabled": (view as? NSControl)?.isEnabled = try arg(0).intValue != 0; return .null
            case "setVisibility": view.isHidden = try arg(0).intValue != 0; return .null
            case "setSingleLine":
                (view as? NSTextField)?.usesSingleLineMode = arguments.isEmpty || arguments[0].intValue != 0
                return .null
            case "setId": target.fields["nativeID"] = try arg(0); return .null
            case "setOnClickListener":
                guard let button = view as? NSButton else { throw AndroidRuntimeError.unsupportedAPI("Click listeners currently require Button") }
                let listener = try arg(0).objectValue
                let action = AndroidButtonAction { [weak self, weak vm] in
                    guard let self, self.failure == nil, let vm, let listener else { return }
                    do {
                        _ = try vm.invoke(receiver: listener, name: "onClick", descriptor: "(Landroid/view/View;)V", arguments: [.object(target)])
                    } catch {
                        self.failure = error
                        for control in self.views.values.compactMap({ $0 as? NSControl }) { control.isEnabled = false }
                        self.onFailure?(error)
                    }
                }
                actions[target.id] = action
                button.target = action
                button.action = #selector(AndroidButtonAction.performClick(_:))
                return .null
            case "performClick":
                actions[target.id]?.performClick(nil)
                return .int(actions[target.id] == nil ? 0 : 1)
            default: break
            }
        }
        throw AndroidRuntimeError.unsupportedAPI("\(owner)->\(name)\(method.descriptor)")
    }

    public func attach(_ view: NSView, to window: NSWindow) {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        window.contentView = container
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
    }

    private func color(_ value: Int32) -> NSColor {
        let bits = UInt32(bitPattern: value)
        return NSColor(srgbRed: CGFloat((bits >> 16) & 255) / 255, green: CGFloat((bits >> 8) & 255) / 255, blue: CGFloat(bits & 255) / 255, alpha: CGFloat((bits >> 24) & 255) / 255)
    }
}

private final class AndroidButtonAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func performClick(_ sender: Any?) { action() }
}
