import UIKit

final class PhotoCell: UICollectionViewCell {
    static let reuseID = "PhotoCell"
    #if targetEnvironment(simulator)
    static var shown = 0, blank = 0
    #endif

    private let imageView = UIImageView()
    private let dim = UIView()
    /// Videos show their length, bottom right, like Photos.
    private let duration = UILabel()
    private let checkBadge = UIImageView()

    private(set) var assetID: String?
    private var isVideo = false
    private var pixels = 0
    private var ticket: MediaCache.Ticket?
    /// The sharp tile being decoded for this cell.
    private var tileOp: Operation?
    private var sharpTask: Task<Void, Never>?
    private var selecting = false
    private var picked = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemFill
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        dim.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        dim.layer.cornerRadius = 9
        dim.layer.cornerCurve = .continuous
        dim.frame = contentView.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dim.alpha = 0
        contentView.addSubview(dim)

        duration.font = .systemFont(ofSize: 13, weight: .semibold)
        duration.textColor = .white
        duration.layer.shadowColor = UIColor.black.cgColor
        duration.layer.shadowOpacity = 0.35
        duration.layer.shadowRadius = 2
        duration.layer.shadowOffset = .zero
        duration.isHidden = true
        contentView.addSubview(duration)
        checkBadge.alpha = 0
        contentView.addSubview(checkBadge)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        let d = duration.intrinsicContentSize
        duration.frame = CGRect(x: b.maxX - 6 - d.width, y: b.maxY - 4 - d.height, width: d.width, height: d.height)
        // the check sits 3 pt in from the corner; the image carries its shadow margin
        let s = checkBadge.image?.size ?? .zero
        checkBadge.bounds = CGRect(origin: .zero, size: s)
        checkBadge.center = CGPoint(x: b.maxX - 3 - (s.width - PhotoCell.shadowPad * 2) / 2,
                                    y: b.maxY - 3 - (s.height - PhotoCell.shadowPad * 2) / 2)
    }

    func configure(_ asset: Asset, pixels: Int, single: Bool, selecting: Bool, picked: Bool) {
        let same = asset.id == assetID && pixels == self.pixels
        isVideo = asset.isVideo
        if let secs = asset.durationS, asset.isVideo {
            let t = Int(secs.rounded())
            duration.text = t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                                      : String(format: "%d:%02d", t / 60, t % 60)
        } else {
            duration.text = nil
        }
        setSelection(selecting: selecting, picked: picked, animated: false, entering: false)
        guard !same || imageView.image == nil else { return }
        stopLoading()
        assetID = asset.id
        self.pixels = pixels
        let id = asset.id
        #if targetEnvironment(simulator)
        Self.shown += 1
        #endif
        let tiles = GridTiles.shared
        if let sharp = tiles.cachedSharp(id) {
            // decoded already (scrolling back)
            imageView.image = UIImage(cgImage: sharp)
        } else if let mini = tiles.mini(id) {
            // the mini at once, the sharp tile a frame or two later
            imageView.image = UIImage(cgImage: mini)
            tileOp = tiles.requestSharp(id) { [weak self] sharp in
                guard let self, self.assetID == id, let sharp else { return }
                self.tileOp = nil
                self.imageView.image = UIImage(cgImage: sharp)
            }
        } else if let img = MediaCache.shared.gridImage(id: id, pixels: pixels) {
            // no tile on the phone yet: the thumbnail, as before
            imageView.image = img
        } else {
            #if targetEnvironment(simulator)
            Self.blank += 1
            #endif
            imageView.image = nil
            ticket = MediaCache.shared.requestGrid(id: id, pixels: pixels, urgent: true) { [weak self] img in
                guard let self, self.assetID == id else { return }
                self.ticket = nil
                self.imageView.image = img
            }
        }
        if single, !asset.isVideo, let url = MediaCache.shared.client.thumbURL(id, 2048) {
            // one photo per row: the 2048 preview, sharp at full width
            let px = CGFloat(pixels)
            sharpTask = Task { [weak self] in
                // only for a cell that stays: a fling through full-width
                // photos would start (and drop) a 2048 download per cell
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                guard let img = await MediaCache.shared.load(url, maxPixel: px * 1.5),
                      let self, self.assetID == id, !Task.isCancelled else { return }
                self.imageView.image = img
            }
        }
    }

    func stopLoading() {
        ticket?.cancel()
        ticket = nil
        tileOp?.cancel()
        tileOp = nil
        sharpTask?.cancel()
        sharpTask = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        stopLoading()
    }

    func setSelection(selecting: Bool, picked: Bool, animated: Bool, entering: Bool) {
        let changed = selecting != self.selecting || picked != self.picked
        self.selecting = selecting
        self.picked = picked
        let apply = {
            // Photos: the picture stays as it is; a picked one gets the blue check,
            // an unpicked one nothing
            self.duration.isHidden = !self.isVideo || picked
            self.checkBadge.image = PhotoCell.checkOn
            self.checkBadge.alpha = selecting && picked ? 1 : 0
            self.checkBadge.transform = selecting && picked ? .identity : CGAffineTransform(scaleX: 0.5, y: 0.5)
            self.setNeedsLayout()
        }
        if animated && changed {
            UIView.animate(springDuration: entering ? 0.35 : 0.26, bounce: 0.05, options: [.allowUserInteraction, .beginFromCurrentState]) {
                apply()
                self.layoutIfNeeded()
            }
        } else {
            apply()
        }
    }

    // MARK: Badges, drawn once with their shadow baked in (a live layer
    // shadow on every cell would be an offscreen pass per frame)

    fileprivate static let shadowPad: CGFloat = 4

    /// White check on a blue disc with a white rim, as in Photos.
    static let checkOn: UIImage = {
        let d: CGFloat = 20, pad = shadowPad
        return UIGraphicsImageRenderer(size: CGSize(width: d + pad * 2, height: d + pad * 2)).image { ctx in
            let c = ctx.cgContext
            c.setShadow(offset: .zero, blur: 3, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor.white.setFill()
            c.fillEllipse(in: CGRect(x: pad, y: pad, width: d, height: d))
            c.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.systemBlue.setFill()
            c.fillEllipse(in: CGRect(x: pad + 1.5, y: pad + 1.5, width: d - 3, height: d - 3))
            let cfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            if let check = UIImage(systemName: "checkmark", withConfiguration: cfg)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                check.draw(at: CGPoint(x: pad + (d - check.size.width) / 2, y: pad + (d - check.size.height) / 2))
            }
        }
    }()
}
