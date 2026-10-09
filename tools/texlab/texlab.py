"""TexLab: PS1 texture prep for Blimp. Originals in assets_src/, results written to assets/ (the engine hot-reloads them).

Run: python tools/texlab/texlab.py [project_root]
"""

import math
import os
import sys

from PySide6.QtCore import (QItemSelectionModel, QObject, QRect, QRunnable, QSettings, QSize, QThreadPool, QTimer,
                            Qt, Signal)
from PySide6.QtGui import QAction, QBrush, QColor, QIcon, QImage, QImageReader, QPainter, QPen, QPixmap
from PySide6.QtWidgets import (QAbstractItemView, QApplication, QCheckBox, QColorDialog, QComboBox, QDialog,
                               QDialogButtonBox, QDoubleSpinBox, QFileDialog, QFormLayout, QGroupBox, QHBoxLayout,
                               QInputDialog, QLabel, QListWidget, QListWidgetItem, QMainWindow, QMenu, QMessageBox,
                               QProgressBar, QPushButton, QScrollArea, QSizePolicy, QSpinBox, QSplitter, QToolBar, QTreeWidget,
                               QTreeWidgetItem, QVBoxLayout, QWidget)

import magick
import project as P

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", ".."))
ZOOMS = ["Fit", "1", "2", "3", "4", "6", "8", "12", "16"]
STATUS_COLORS = {"built": "#5cb85c", "stale": "#e0a030", "not built": "#888888", "error": "#d9534f"}
MIXED_STYLE = "color: #e0a030;"


def round_pow2(x: float) -> int:
    return 2 ** max(0, round(math.log2(max(x, 1))))


def checker_brush() -> QBrush:
    pm = QPixmap(16, 16)
    pm.fill(QColor(60, 60, 60))
    p = QPainter(pm)
    p.fillRect(0, 0, 8, 8, QColor(80, 80, 80))
    p.fillRect(8, 8, 8, 8, QColor(80, 80, 80))
    p.end()
    return QBrush(pm)


# --- background jobs ---------------------------------------------------------------------------

class JobSignals(QObject):
    done = Signal(object)


class Job(QRunnable):
    """Runs fn on the pool; done(result or Exception) is called on the UI thread."""

    def __init__(self, fn, done):
        super().__init__()
        self.fn = fn
        self.signals = JobSignals()
        self.signals.done.connect(done, Qt.ConnectionType.QueuedConnection)

    def run(self):
        try:
            result = self.fn()
        except Exception as e:  # reported on the UI thread
            result = e
        self.signals.done.emit(result)


# --- widgets -----------------------------------------------------------------------------------

class Pow2Spin(QSpinBox):
    """Arrows step through powers of two; any value can still be typed."""

    def __init__(self):
        super().__init__()
        self.setRange(1, 4096)
        self.setKeyboardTracking(False)

    def stepBy(self, steps: int):
        v = self.value()
        for _ in range(abs(steps)):
            if steps > 0:
                v = v * 2 if P.is_pow2(v) else P.pow2_floor(v) * 2
            else:
                v = max(1, v // 2 if P.is_pow2(v) else P.pow2_floor(v))
        self.setValue(min(v, self.maximum()))


class ColorSpin(QSpinBox):
    """Palette size. Arrows step through common counts; any value 2-256 can be typed."""
    STEPS = [2, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256]

    def __init__(self):
        super().__init__()
        self.setRange(2, 256)
        self.setKeyboardTracking(False)

    def stepBy(self, steps: int):
        v = self.value()
        for _ in range(abs(steps)):
            v = next((s for s in self.STEPS if s > v), 256) if steps > 0 else                 next((s for s in reversed(self.STEPS) if s < v), 2)
        self.setValue(v)


class ViewState(QObject):
    """Zoom and pan shared by the source and result views."""
    changed = Signal()

    def __init__(self):
        super().__init__()
        self.zoom = 0.0  # 0 = fit
        self.pan_x = 0
        self.pan_y = 0
        self.tile = False


class PixelView(QWidget):
    """Draws an image into a (width x height) x zoom rect. The source uses smooth scaling, the result nearest."""

    def __init__(self, state: ViewState, smooth: bool, title: str):
        super().__init__()
        self.state = state
        self.smooth = smooth
        self.title = title
        self.image: QImage | None = None
        self.size_px = (1, 1)
        self.drag = None
        self.checker = checker_brush()
        self.setMinimumSize(200, 200)
        state.changed.connect(self.update)

    def zoom(self) -> float:
        if self.state.zoom:
            return self.state.zoom
        n = 3 if self.state.tile else 1
        z = min(self.width() / (self.size_px[0] * n), (self.height() - 20) / (self.size_px[1] * n))
        return math.floor(z) if z >= 1 else z

    def paintEvent(self, _):
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(35, 35, 35))
        z = self.zoom()
        w, h = self.size_px[0] * z, self.size_px[1] * z
        x0 = (self.width() - w) / 2 + self.state.pan_x
        y0 = (self.height() - h) / 2 + self.state.pan_y
        if self.image is not None:
            p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, self.smooth)
            r = range(-1, 2) if self.state.tile else range(0, 1)
            for ty in r:
                for tx in r:
                    rect = (int(x0 + tx * w), int(y0 + ty * h), int(round(w)), int(round(h)))
                    p.fillRect(*rect, self.checker)
                    p.drawImage(QRect(*rect), self.image)
        p.setPen(QColor(200, 200, 200))
        p.drawText(6, 16, self.title)

    def mousePressEvent(self, e):
        self.drag = e.position()

    def mouseMoveEvent(self, e):
        if self.drag is not None:
            d = e.position() - self.drag
            self.drag = e.position()
            self.state.pan_x += int(d.x())
            self.state.pan_y += int(d.y())
            self.state.changed.emit()

    def mouseReleaseEvent(self, _):
        self.drag = None

    def mouseDoubleClickEvent(self, _):
        self.state.pan_x = self.state.pan_y = 0
        self.state.changed.emit()

    def wheelEvent(self, e):
        z = self.zoom()
        z = z * 2 if e.angleDelta().y() > 0 else z / 2
        self.state.zoom = max(0.125, min(64.0, z))
        self.state.changed.emit()


class PaletteStrip(QWidget):
    """Swatch grid. Locked swatches have a corner mark; the transparent entry is drawn as a checker."""
    edit = Signal(int)
    menu = Signal(int, object)

    CELL = 18

    def __init__(self):
        super().__init__()
        self.colors: list[magick.Color] = []
        self.locked = 0
        self.alpha = False
        self.checker = checker_brush()
        self.setMouseTracking(True)

    def set(self, colors, locked: int, alpha: bool):
        self.colors, self.locked, self.alpha = colors, locked, alpha
        self.updateGeometry()
        self.update()

    def cols(self) -> int:
        return max(1, min(32, self.width() // self.CELL))

    def count(self) -> int:
        return len(self.colors) + self.alpha

    def sizeHint(self):
        return QSize(32 * self.CELL, max(1, math.ceil(self.count() / 32)) * self.CELL)

    def hasHeightForWidth(self):
        return True

    def heightForWidth(self, w):
        return max(1, math.ceil(self.count() / max(1, min(32, w // self.CELL)))) * self.CELL

    def index_at(self, pos) -> int:
        i = int(pos.y()) // self.CELL * self.cols() + int(pos.x()) // self.CELL
        return i if 0 <= int(pos.x()) < self.cols() * self.CELL and i < len(self.colors) else -1

    def paintEvent(self, _):
        p = QPainter(self)
        c, s = self.cols(), self.CELL
        for i in range(self.count()):
            x, y = i % c * s, i // c * s
            if i == len(self.colors):
                p.fillRect(x, y, s - 1, s - 1, self.checker)
                continue
            p.fillRect(x, y, s - 1, s - 1, QColor(*self.colors[i]))
            if i < self.locked:
                lum = sum(self.colors[i]) / 3
                p.setPen(QPen(QColor(0, 0, 0) if lum > 128 else QColor(255, 255, 255), 2))
                p.drawLine(x + 2, y + 2, x + 7, y + 2)
                p.drawLine(x + 2, y + 2, x + 2, y + 7)

    def mouseMoveEvent(self, e):
        i = self.index_at(e.position())
        self.setToolTip(f"{i}: {magick.to_hex(self.colors[i])}{'  (locked)' if i < self.locked else ''}"
                        if i >= 0 else "")

    def mouseDoubleClickEvent(self, e):
        i = self.index_at(e.position())
        if i >= 0:
            self.edit.emit(i)

    def contextMenuEvent(self, e):
        self.menu.emit(self.index_at(e.pos()), e.globalPos())


class AdoptDialog(QDialog):
    def __init__(self, parent, rels: list[str]):
        super().__init__(parent)
        self.setWindowTitle("Adopt textures from assets/")
        self.list = QListWidget()
        for rel in rels:
            it = QListWidgetItem(rel)
            it.setFlags(it.flags() | Qt.ItemFlag.ItemIsUserCheckable)
            it.setCheckState(Qt.CheckState.Checked)
            self.list.addItem(it)
        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        lay = QVBoxLayout(self)
        lay.addWidget(QLabel("Copies the current texture into assets_src/ as the full-res original.\n"
                             "The file in assets/ is only replaced when you Build."))
        lay.addWidget(self.list)
        lay.addWidget(buttons)
        self.resize(520, 480)

    def checked(self) -> list[str]:
        return [self.list.item(i).text() for i in range(self.list.count())
                if self.list.item(i).checkState() == Qt.CheckState.Checked]


# --- main window -------------------------------------------------------------------------------

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.proj = P.Project(ROOT)
        self.pool = QThreadPool()
        self.pool.setMaxThreadCount(4)
        self.jobs: set[Job] = set()
        self.src_sizes: dict[str, tuple[float, tuple[int, int]]] = {}
        self.thumbs: dict[str, tuple[float, QIcon]] = {}
        self.src_images: dict[str, tuple[float, QImage]] = {}
        self.preview_gen = 0
        self.result_image: QImage | None = None
        self.result_palette: list[magick.Color] = []
        self.result_alpha = False
        self.building: dict[str, str] = {}  # rel -> build key, for the batch in flight
        self.build_errors: list[str] = []
        self.loading = False

        self.setWindowTitle(f"TexLab - {ROOT}")
        self.save_timer = QTimer(self, singleShot=True, interval=400, timeout=self.proj.save)
        self.preview_timer = QTimer(self, singleShot=True, interval=150, timeout=self.run_preview)

        self.make_toolbar()
        left = self.make_left()
        center = self.make_center()
        right = self.make_settings()
        self.split = QSplitter()
        for w in (left, center, right):
            self.split.addWidget(w)
        self.split.setStretchFactor(1, 1)
        self.setCentralWidget(self.split)

        settings = QSettings("blimp", "texlab")
        if settings.value("geometry"):
            self.restoreGeometry(settings.value("geometry"))
            self.split.restoreState(settings.value("split"))
        else:
            self.resize(1700, 950)
            self.split.setSizes([780, 580, 340])

        self.build_tree()
        if not magick.MAGICK:
            QMessageBox.warning(self, "TexLab", "ImageMagick (magick.exe) was not found on PATH or in Program Files.")

    def closeEvent(self, e):
        self.proj.save()
        settings = QSettings("blimp", "texlab")
        settings.setValue("geometry", self.saveGeometry())
        settings.setValue("split", self.split.saveState())
        super().closeEvent(e)

    # --- layout ---

    def make_toolbar(self):
        tb = QToolBar("Main")
        tb.setMovable(False)
        self.addToolBar(tb)
        for text, tip, fn in [
            ("Adopt from assets/...", "Copy textures from assets/ into assets_src/ as originals", self.adopt),
            ("Rescan", "Pick up new files in assets_src/", self.rescan),
            (None, None, None),
            ("Build selected", "Write the selected textures into assets/ (Ctrl+B)", self.build_selected),
            ("Build stale", "Build every texture that is not built or out of date", self.build_stale),
            ("Build all", "Rebuild every texture", self.build_all),
            (None, None, None),
            ("Open assets_src", "Open the originals folder in Explorer", lambda: os.startfile(self.proj.src_dir)),
        ]:
            if text is None:
                tb.addSeparator()
                continue
            a = QAction(text, self)
            a.setToolTip(tip)
            a.triggered.connect(fn)
            tb.addAction(a)
            if text == "Build selected":
                a.setShortcut("Ctrl+B")
        spacer = QWidget()
        spacer.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Preferred)
        tb.addWidget(spacer)
        ver = magick.version()
        tb.addWidget(QLabel(f"ImageMagick {ver}  " if ver else "ImageMagick missing  "))

    def make_left(self) -> QWidget:
        self.tree = QTreeWidget()
        self.tree.setHeaderLabels(["Texture", "Size", "New size", "Palette", "VRAM", "Status"])
        self.tree.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.tree.setIconSize(QSize(32, 32))
        self.tree.setRootIsDecorated(True)
        self.tree.itemSelectionChanged.connect(self.selection_changed)
        self.tree.currentItemChanged.connect(lambda *_: self.selection_changed())
        self.tree.itemClicked.connect(self.item_clicked)
        self.tree.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.tree.customContextMenuRequested.connect(self.tree_menu)

        self.vram_bar = QProgressBar()
        self.vram_bar.setRange(0, P.VRAM_BYTES // 1024)
        self.vram_bar.setTextVisible(False)
        self.vram_bar.setFixedHeight(10)
        self.vram_label = QLabel()
        self.vram_label.setWordWrap(True)

        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(self.tree)
        lay.addWidget(QLabel("<b>PS1 VRAM estimate</b>"))
        lay.addWidget(self.vram_bar)
        lay.addWidget(self.vram_label)
        return w

    def make_center(self) -> QWidget:
        self.view_state = ViewState()
        self.zoom_combo = QComboBox()
        self.zoom_combo.addItems([z if z == "Fit" else z + "x" for z in ZOOMS])
        self.zoom_combo.currentIndexChanged.connect(self.zoom_picked)
        self.view_state.changed.connect(self.sync_zoom_combo)
        self.tile_check = QCheckBox("Tile 3x3")
        self.tile_check.toggled.connect(self.tile_toggled)
        self.index_check = QCheckBox("Palette indices")
        self.index_check.setToolTip("Show each palette entry as a distinct colour, to see dither noise and banding")
        self.index_check.toggled.connect(self.show_result)
        self.info_label = QLabel()

        bar = QHBoxLayout()
        bar.addWidget(QLabel("Zoom"))
        bar.addWidget(self.zoom_combo)
        bar.addWidget(self.tile_check)
        bar.addWidget(self.index_check)
        bar.addStretch(1)
        bar.addWidget(self.info_label)

        self.source_view = PixelView(self.view_state, True, "Source")
        self.result_view = PixelView(self.view_state, False, "Result")
        views = QSplitter()
        views.addWidget(self.source_view)
        views.addWidget(self.result_view)

        self.palette_label = QLabel()
        self.strip = PaletteStrip()
        self.strip.edit.connect(self.edit_swatch)
        self.strip.menu.connect(self.swatch_menu)
        pal_buttons = QHBoxLayout()
        for text, tip, fn in [("+ Colour", "Add a locked colour", self.add_swatch),
                              ("Unlock all", "Remove every locked colour", self.unlock_all),
                              ("Import...", "Load a palette file as locked colours", self.import_palette),
                              ("Export...", "Save the current palette", self.export_palette)]:
            b = QPushButton(text)
            b.setToolTip(tip)
            b.clicked.connect(fn)
            pal_buttons.addWidget(b)
        pal_buttons.addStretch(1)
        self.pal_buttons = pal_buttons

        w = QWidget()
        lay = QVBoxLayout(w)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addLayout(bar)
        lay.addWidget(views, 1)
        lay.addWidget(self.palette_label)
        lay.addWidget(self.strip)
        lay.addLayout(pal_buttons)
        lay.addWidget(QLabel("<small>Double-click a swatch to edit it (edited colours are locked). "
                             "Right-click to lock, unlock or remove. Locked colours are always kept; "
                             "the rest are derived from the textures.</small>"))
        return w

    def make_settings(self) -> QWidget:
        self.labels: dict[str, QLabel] = {}

        def row(form: QFormLayout, key: str, text: str, widget: QWidget, tip: str = ""):
            label = QLabel(text)
            label.setToolTip(tip)
            widget.setToolTip(tip)
            self.labels[key] = label
            form.addRow(label, widget)

        def spin(lo, hi, step=1, decimals=None):
            s = QDoubleSpinBox() if decimals is not None else QSpinBox()
            if decimals is not None:
                s.setDecimals(decimals)
            s.setRange(lo, hi)
            s.setSingleStep(step)
            s.setKeyboardTracking(False)
            return s

        self.selection_label = QLabel()

        # size
        size_box = QGroupBox("Size")
        form = QFormLayout(size_box)
        self.max_side = QComboBox()
        self.max_side.addItems(["Set..."] + [str(s) for s in (16, 32, 64, 128, 256, 512)])
        self.max_side.activated.connect(self.max_side_picked)
        row(form, "max_side", "Max side", self.max_side,
            "Set each selected texture's longer side, keeping its aspect (sides snap to powers of two)")
        self.width_spin = Pow2Spin()
        self.height_spin = Pow2Spin()
        self.width_spin.valueChanged.connect(lambda v: self.size_edited("width", v))
        self.height_spin.valueChanged.connect(lambda v: self.size_edited("height", v))
        row(form, "width", "Width", self.width_spin, "Arrows step through powers of two")
        row(form, "height", "Height", self.height_spin, "Arrows step through powers of two")
        self.keep_aspect = QCheckBox("Keep source aspect")
        form.addRow("", self.keep_aspect)
        self.filter_combo = QComboBox()
        self.filter_combo.addItems(magick.FILTERS)
        self.filter_combo.currentTextChanged.connect(lambda v: self.set_field("filter", v))
        row(form, "filter", "Filter", self.filter_combo,
            "Point: nearest pixel (crisp, aliased). Box: average (good for big reductions). "
            "Triangle: soft. Lanczos: sharp, can ring")

        # adjustments
        adj_box = QGroupBox("Adjust (before palette)")
        form = QFormLayout(adj_box)
        self.brightness_spin = spin(-100, 100)
        self.contrast_spin = spin(-100, 100)
        self.saturation_spin = spin(0, 300, 5)
        self.gamma_spin = spin(0.1, 5.0, 0.05, 2)
        self.sharpen_spin = spin(0.0, 5.0, 0.1, 2)
        self.cutoff_spin = spin(0, 255)
        for key, text, w, tip in [
            ("brightness", "Brightness", self.brightness_spin, ""),
            ("contrast", "Contrast", self.contrast_spin, ""),
            ("saturation", "Saturation %", self.saturation_spin, "100 = unchanged"),
            ("gamma", "Gamma", self.gamma_spin, "1 = unchanged; above 1 brightens mid-tones"),
            ("sharpen", "Sharpen", self.sharpen_spin, "Unsharp mask after resizing, so small textures keep edges"),
            ("alpha_cutoff", "Alpha cutoff", self.cutoff_spin,
             "Alpha above this is opaque, the rest fully transparent (1-bit, like the PS1)"),
        ]:
            w.valueChanged.connect(lambda v, k=key: self.set_field(k, v))
            row(form, key, text, w, tip)
        reset = QPushButton("Reset adjustments")
        reset.clicked.connect(self.reset_adjust)
        form.addRow("", reset)

        # palette
        pal_box = QGroupBox("Colour")
        form = QFormLayout(pal_box)
        self.mode_combo = QComboBox()
        self.mode_combo.activated.connect(self.mode_picked)
        row(form, "palette", "Palette", self.mode_combo,
            "None: truecolour. Own: one palette per texture (a PS1 CLUT). A group: one palette shared by all members")
        group_buttons = QHBoxLayout()
        for text, fn in [("New group...", self.new_group), ("Rename...", self.rename_group),
                         ("Delete", self.delete_group)]:
            b = QPushButton(text)
            b.clicked.connect(fn)
            group_buttons.addWidget(b)
        form.addRow("", group_buttons)
        self.colors_spin = ColorSpin()
        self.colors_spin.valueChanged.connect(self.colors_picked)
        row(form, "colors", "Colours", self.colors_spin,
            "Up to 16: a 4-bit texture with a 16-entry CLUT. 17-256: an 8-bit texture with a 256-entry CLUT. "
            "Within each band fewer colours cost the same VRAM; it is a look choice")
        self.rgb555_check = QCheckBox("15-bit colour (RGB555)")
        self.rgb555_check.toggled.connect(self.rgb555_toggled)
        row(form, "rgb555", "", self.rgb555_check, "Snap colours to the 32 levels per channel PS1 VRAM stores")
        self.dither_combo = QComboBox()
        self.dither_combo.addItems(magick.DITHERS)
        self.dither_combo.currentTextChanged.connect(lambda v: self.set_field("dither", v))
        row(form, "dither", "Dither", self.dither_combo,
            "Error diffusion when mapping to the palette. The engine's retro view already adds ordered "
            "dither, so None is often enough")

        self.problem_label = QLabel()
        self.problem_label.setWordWrap(True)
        self.problem_label.setStyleSheet("color: #d9534f;")

        w = QWidget()
        lay = QVBoxLayout(w)
        lay.addWidget(self.selection_label)
        lay.addWidget(self.problem_label)
        lay.addWidget(size_box)
        lay.addWidget(adj_box)
        lay.addWidget(pal_box)
        lay.addStretch(1)
        self.settings_widget = w
        scroll = QScrollArea()
        scroll.setWidget(w)
        scroll.setWidgetResizable(True)
        return scroll

    # --- tree ---

    def src_size(self, rel: str) -> tuple[int, int]:
        path = self.proj.src(rel)
        mtime = os.path.getmtime(path) if os.path.exists(path) else 0
        cached = self.src_sizes.get(rel)
        if cached is None or cached[0] != mtime:
            cached = (mtime, magick.image_size(path) if mtime else (0, 0))
            self.src_sizes[rel] = cached
        return cached[1]

    def thumb(self, rel: str) -> QIcon:
        path = self.proj.src(rel)
        mtime = os.path.getmtime(path) if os.path.exists(path) else 0
        cached = self.thumbs.get(rel)
        if cached is None or cached[0] != mtime:
            reader = QImageReader(path)
            s = reader.size()
            if s.width() > 0:
                k = 32 / max(s.width(), s.height())
                reader.setScaledSize(QSize(max(1, int(s.width() * k)), max(1, int(s.height() * k))))
            cached = (mtime, QIcon(QPixmap.fromImage(reader.read())))
            self.thumbs[rel] = cached
        return cached[1]

    def build_tree(self):
        selected = set(self.selected_rels())
        current = self.current_rel()
        self.tree.blockSignals(True)
        self.tree.clear()
        folders: dict[str, QTreeWidgetItem] = {}
        for rel in sorted(self.proj.textures):
            folder = os.path.dirname(rel) or "."
            parent = folders.get(folder)
            if parent is None:
                parent = QTreeWidgetItem(self.tree, [folder])
                parent.setFirstColumnSpanned(True)
                parent.setExpanded(True)
                folders[folder] = parent
            it = QTreeWidgetItem(parent, [os.path.basename(rel)])
            it.setData(0, Qt.ItemDataRole.UserRole, rel)
            it.setIcon(0, self.thumb(rel))
            it.setSelected(rel in selected)
            if rel == current:
                self.tree.setCurrentItem(it, 0, QItemSelectionModel.SelectionFlag.NoUpdate)
        self.tree.blockSignals(False)
        self.update_rows()
        for i in range(self.tree.columnCount()):  # after update_rows, so the columns fit their text
            self.tree.resizeColumnToContents(i)
            self.tree.setColumnWidth(i, self.tree.columnWidth(i) + 12)
        self.tree.setColumnWidth(0, max(180, min(self.tree.columnWidth(0), 260)))  # long names show as tooltips
        self.selection_changed()

    def texture_items(self):
        for i in range(self.tree.topLevelItemCount()):
            folder = self.tree.topLevelItem(i)
            for j in range(folder.childCount()):
                yield folder.child(j)

    def update_rows(self):
        for it in self.texture_items():
            rel = it.data(0, Qt.ItemDataRole.UserRole)
            t = self.proj.textures[rel]
            sw, sh = self.src_size(rel)
            pal = self.proj.palette_of(t)
            pal_text = "truecolour" if t.palette == "none" else \
                f"own {pal.colors}" if t.palette == "own" else f"{t.palette} ({pal.colors if pal else '?'})"
            status = self.proj.status(rel)
            notes = [self.proj.problem(rel)] if self.proj.problem(rel) else self.proj.warnings(rel)
            it.setText(1, f"{sw}x{sh}")
            it.setText(2, "" if (sw, sh) == (t.width, t.height) else f"{t.width}x{t.height}")
            it.setText(3, pal_text)
            it.setText(4, "" if status == "error" else f"{self.proj.vram(rel) / 1024:.1f} KB")
            it.setText(5, status + (" (!)" if notes else ""))
            it.setForeground(5, QBrush(QColor(STATUS_COLORS[status])))
            it.setToolTip(5, "\n".join(notes))
            it.setToolTip(0, rel)
        self.update_vram()

    def update_vram(self):
        tex = self.proj.vram_total()
        total = tex + P.FRAMEBUFFER_BYTES
        self.vram_bar.setValue(min(total, P.VRAM_BYTES) // 1024)
        over = total > P.VRAM_BYTES
        self.vram_bar.setStyleSheet("QProgressBar::chunk { background: %s; }" % ("#d9534f" if over else "#5b9bd5"))
        warn = sum(1 for r in self.proj.textures if self.proj.problem(r) or self.proj.warnings(r))
        self.vram_label.setText(
            f"Textures + CLUTs {tex / 1024:.0f} KB + framebuffers {P.FRAMEBUFFER_BYTES / 1024:.0f} KB "
            f"= {total / 1024:.0f} / {P.VRAM_BYTES // 1024} KB" + (f"<br>{warn} texture(s) flagged (!)" if warn else "")
            + "<br><small>4-bit for 16 colours, 8-bit for 256, 16-bit truecolour. Informational: "
              "Blimp itself uploads RGBA8.</small>")

    def item_clicked(self, item: QTreeWidgetItem, _col: int):
        if item.data(0, Qt.ItemDataRole.UserRole) is None:  # folder: select its textures
            self.tree.blockSignals(True)
            if not QApplication.keyboardModifiers() & Qt.KeyboardModifier.ControlModifier:
                self.tree.clearSelection()
            item.setSelected(False)
            for j in range(item.childCount()):
                item.child(j).setSelected(True)
            if item.childCount():
                self.tree.setCurrentItem(item.child(0), 0, QItemSelectionModel.SelectionFlag.NoUpdate)
            self.tree.blockSignals(False)
            self.selection_changed()

    def selected_rels(self) -> list[str]:
        return [it.data(0, Qt.ItemDataRole.UserRole) for it in self.tree.selectedItems()
                if it.data(0, Qt.ItemDataRole.UserRole) is not None]

    def current_rel(self) -> str | None:
        it = self.tree.currentItem()
        rel = it.data(0, Qt.ItemDataRole.UserRole) if it else None
        sel = self.selected_rels()
        if rel in sel:
            return rel
        return sel[0] if sel else None

    # --- settings panel ---

    def field_value(self, key: str, rel: str):
        t = self.proj.textures[rel]
        pal = self.proj.palette_of(t)
        if key == "colors":
            return pal.colors if pal else None
        if key == "rgb555":
            return pal.rgb555 if pal else t.rgb555
        return getattr(t, key)

    def selection_changed(self):
        rels = self.selected_rels()
        rel = self.current_rel()
        self.settings_widget.setEnabled(rel is not None)
        self.selection_label.setText(f"<b>{len(rels)} textures selected</b> (amber = values differ; "
                                     f"edits apply to all)" if len(rels) > 1 else f"<b>{rel or 'Nothing selected'}</b>")
        if rel is None:
            self.clear_preview()
            return
        t = self.proj.textures[rel]
        self.loading = True
        self.width_spin.setValue(t.width)
        self.height_spin.setValue(t.height)
        self.filter_combo.setCurrentText(t.filter)
        self.brightness_spin.setValue(t.brightness)
        self.contrast_spin.setValue(t.contrast)
        self.saturation_spin.setValue(t.saturation)
        self.gamma_spin.setValue(t.gamma)
        self.sharpen_spin.setValue(t.sharpen)
        self.cutoff_spin.setValue(t.alpha_cutoff)
        self.fill_mode_combo(t.palette)
        pal = self.proj.palette_of(t)
        self.colors_spin.setEnabled(pal is not None)
        if pal:
            self.colors_spin.setValue(pal.colors)
        self.rgb555_check.setChecked(pal.rgb555 if pal else t.rgb555)
        self.dither_combo.setCurrentText(t.dither)
        self.dither_combo.setEnabled(pal is not None)
        self.loading = False
        for key, label in self.labels.items():
            if key == "max_side":
                continue
            mixed = len({repr(self.field_value(key, r)) for r in rels}) > 1
            label.setStyleSheet(MIXED_STYLE if mixed else "")
        problems = [f"{os.path.basename(r)}: {self.proj.problem(r)}" for r in rels if self.proj.problem(r)]
        self.problem_label.setText("<br>".join(problems))
        self.problem_label.setVisible(bool(problems))
        self.preview_timer.start()

    def fill_mode_combo(self, current: str):
        self.mode_combo.clear()
        self.mode_combo.addItem("None (truecolour)", "none")
        self.mode_combo.addItem("Own palette", "own")
        for name in sorted(self.proj.groups):
            self.mode_combo.addItem(f"Group: {name}", name)
        self.mode_combo.setCurrentIndex(max(0, self.mode_combo.findData(current)))

    def changed(self):
        self.save_timer.start()
        self.update_rows()
        self.selection_changed()

    def set_field(self, key: str, value):
        if self.loading:
            return
        for rel in self.selected_rels():
            setattr(self.proj.textures[rel], key, value)
        self.changed()

    def size_edited(self, key: str, value: int):
        if self.loading:
            return
        for rel in self.selected_rels():
            t = self.proj.textures[rel]
            setattr(t, key, value)
            if self.keep_aspect.isChecked():
                sw, sh = self.src_size(rel)
                other = value * (sh / sw if key == "width" else sw / sh)
                other = round_pow2(other) if P.is_pow2(value) else max(1, round(other))
                setattr(t, "height" if key == "width" else "width", other)
        self.changed()

    def max_side_picked(self, index: int):
        if index == 0:
            return
        side = int(self.max_side.currentText())
        for rel in self.selected_rels():
            sw, sh = self.src_size(rel)
            t = self.proj.textures[rel]
            if sw >= sh:
                t.width, t.height = side, min(side, round_pow2(side * sh / sw))
            else:
                t.width, t.height = min(side, round_pow2(side * sw / sh)), side
        self.max_side.setCurrentIndex(0)
        self.changed()

    def reset_adjust(self):
        for rel in self.selected_rels():
            t = self.proj.textures[rel]
            t.brightness, t.contrast, t.saturation, t.gamma, t.sharpen = 0, 0, 100, 1.0, 0.0
        self.changed()

    def mode_picked(self, index: int):
        self.set_field("palette", self.mode_combo.itemData(index))

    def selected_palettes(self) -> list[P.Palette]:
        out = []
        for rel in self.selected_rels():
            pal = self.proj.palette_of(self.proj.textures[rel])
            if pal is not None and all(pal is not p for p in out):
                out.append(pal)
        return out

    def colors_picked(self, value: int):
        if self.loading:
            return
        for pal in self.selected_palettes():
            pal.colors = value
        self.changed()

    def rgb555_toggled(self, on: bool):
        if self.loading:
            return
        for rel in self.selected_rels():
            t = self.proj.textures[rel]
            if self.proj.palette_of(t) is None:
                t.rgb555 = on
        for pal in self.selected_palettes():
            pal.rgb555 = on
        self.changed()

    def new_group(self):
        rels = self.selected_rels()
        name, ok = QInputDialog.getText(self, "New palette group",
                                        f"Name for a palette shared by the {len(rels)} selected textures:")
        name = name.strip()
        if not ok or not name:
            return
        if name in ("none", "own") or name in self.proj.groups:
            QMessageBox.warning(self, "TexLab", f"'{name}' is already taken.")
            return
        self.proj.groups[name] = P.Palette(colors=16)
        for rel in rels:
            self.proj.textures[rel].palette = name
        self.changed()

    def current_group(self) -> str | None:
        rel = self.current_rel()
        name = self.proj.textures[rel].palette if rel else None
        return name if name in self.proj.groups else None

    def rename_group(self):
        old = self.current_group()
        if old is None:
            return
        new, ok = QInputDialog.getText(self, "Rename group", "New name:", text=old)
        new = new.strip()
        if not ok or not new or new == old or new in ("none", "own") or new in self.proj.groups:
            return
        self.proj.groups[new] = self.proj.groups.pop(old)
        for t in self.proj.textures.values():
            if t.palette == old:
                t.palette = new
        self.changed()

    def delete_group(self):
        name = self.current_group()
        if name is None:
            return
        n = sum(1 for t in self.proj.textures.values() if t.palette == name)
        if QMessageBox.question(self, "Delete group", f"Delete '{name}'? Its {n} textures go back to own palettes."
                                ) != QMessageBox.StandardButton.Yes:
            return
        del self.proj.groups[name]
        for t in self.proj.textures.values():
            if t.palette == name:
                t.palette = "own"
        self.changed()

    # --- palette strip ---

    def active_palette(self) -> P.Palette | None:
        rel = self.current_rel()
        return self.proj.palette_of(self.proj.textures[rel]) if rel else None

    def edit_swatch(self, i: int):
        pal = self.active_palette()
        if pal is None:
            return
        c = QColorDialog.getColor(QColor(*self.result_palette[i]), self, "Edit colour")
        if not c.isValid():
            return
        h = magick.to_hex((c.red(), c.green(), c.blue()))
        if i < len(pal.locked):
            pal.locked[i] = h
        else:
            pal.locked.append(h)
        self.changed()

    def swatch_menu(self, i: int, pos):
        pal = self.active_palette()
        if pal is None or i < 0:
            return
        menu = QMenu(self)
        locked = i < len(pal.locked)
        lock = menu.addAction("Unlock" if locked else "Lock")
        edit = menu.addAction("Edit colour...")
        remove = menu.addAction("Remove") if locked else None
        picked = menu.exec(pos)
        if picked is None:
            return
        if picked == edit:
            self.edit_swatch(i)
            return
        if locked:
            del pal.locked[i]
        else:
            pal.locked.append(magick.to_hex(self.result_palette[i]))
        self.changed()

    def add_swatch(self):
        pal = self.active_palette()
        if pal is None:
            return
        c = QColorDialog.getColor(QColor(128, 128, 128), self, "Add locked colour")
        if c.isValid():
            pal.locked.append(magick.to_hex((c.red(), c.green(), c.blue())))
            self.changed()

    def unlock_all(self):
        pal = self.active_palette()
        if pal is not None and pal.locked:
            pal.locked = []
            self.changed()

    def import_palette(self):
        pal = self.active_palette()
        if pal is None:
            QMessageBox.information(self, "TexLab", "Pick a texture that uses a palette (own or group) first.")
            return
        path, _ = QFileDialog.getOpenFileName(self, "Import palette", "", magick.PALETTE_FILTER)
        if not path:
            return
        try:
            colors = magick.load_palette(path)
        except Exception as e:
            QMessageBox.warning(self, "TexLab", f"Could not read {path}:\n{e}")
            return
        if len(colors) > pal.colors:
            pal.colors = min(len(colors), 256)
        pal.locked = [magick.to_hex(c) for c in colors[:pal.colors]]
        self.statusBar().showMessage(f"Imported {len(pal.locked)} colours as locked swatches"
                                     + (f" ({len(colors) - pal.colors} dropped)" if len(colors) > pal.colors else ""))
        self.changed()

    def export_palette(self):
        if not self.result_palette:
            return
        path, _ = QFileDialog.getSaveFileName(self, "Export palette", "palette.gpl", magick.PALETTE_FILTER)
        if path:
            magick.save_palette(path, self.result_palette)
            self.statusBar().showMessage(f"Saved {len(self.result_palette)} colours to {path}")

    # --- preview ---

    def source_image(self, rel: str) -> QImage:
        path = self.proj.src(rel)
        mtime = os.path.getmtime(path)
        cached = self.src_images.get(rel)
        if cached is None or cached[0] != mtime:
            cached = (mtime, QImage(path))
            self.src_images[rel] = cached
        return cached[1]

    def clear_preview(self):
        self.result_image = None
        self.result_palette = []
        for v in (self.source_view, self.result_view):
            v.image = None
            v.update()
        self.strip.set([], 0, False)
        self.palette_label.setText("")
        self.info_label.setText("")

    def run_preview(self):
        rel = self.current_rel()
        if rel is None or self.proj.problem(rel):
            self.clear_preview()
            if rel is not None:
                self.source_view.image = self.source_image(rel) if os.path.exists(self.proj.src(rel)) else None
            return
        t = self.proj.textures[rel]
        self.source_view.image = self.source_image(rel)
        for v in (self.source_view, self.result_view):
            v.size_px = (t.width, t.height)
            v.update()
        self.preview_gen += 1
        gen = self.preview_gen
        snap = self.proj.snapshot()
        out = os.path.join(P.CACHE_DIR, f"preview_{gen}.png")
        os.makedirs(P.CACHE_DIR, exist_ok=True)
        alpha_of = lambda: P.swatches(snap, rel)[1] if snap.palette_of(snap.textures[rel]) else False
        self.info_label.setText("working...")
        self.start_job(lambda: (gen, rel, out, P.build(snap, rel, out), alpha_of()), self.preview_done)

    def preview_done(self, result):
        if isinstance(result, Exception):
            self.info_label.setText("error")
            self.statusBar().showMessage(f"Preview failed: {result}")
            return
        gen, rel, out, palette, alpha = result
        if gen == self.preview_gen:
            self.result_image = QImage(out)
            self.result_palette = palette
            self.result_alpha = alpha
            t = self.proj.textures[rel]
            pal = self.proj.palette_of(t)
            n = len(palette) + alpha
            self.info_label.setText(
                f"{t.width}x{t.height}  {f'{n} entries' if pal else 'truecolour'}  "
                f"{self.proj.bpp(t)}-bit  {self.proj.vram(rel) / 1024:.1f} KB")
            self.strip.set(palette, len(pal.locked) if pal else 0, alpha)
            if pal is None:
                self.palette_label.setText("<b>Palette</b>: none (truecolour)")
            else:
                who = "own" if t.palette == "own" else f"group '{t.palette}', shared by {len(self.proj.members(rel))}"
                self.palette_label.setText(
                    f"<b>Palette</b>: {who}; {len(palette)} colours{' + transparent' if alpha else ''}, "
                    f"{min(len(pal.locked), len(palette))} locked")
            self.show_result()
        try:
            os.remove(out)
        except OSError:
            pass

    def show_result(self):
        img = self.result_image
        if img is not None and self.index_check.isChecked() and self.result_palette:
            img = index_image(img, self.result_palette)
        self.result_view.image = img
        self.result_view.update()

    def zoom_picked(self, index: int):
        self.view_state.zoom = 0.0 if index == 0 else float(ZOOMS[index])
        self.view_state.changed.emit()

    def sync_zoom_combo(self):
        text = "Fit" if not self.view_state.zoom else f"{self.view_state.zoom:g}x"
        self.zoom_combo.blockSignals(True)
        i = self.zoom_combo.findText(text)
        if i < 0:
            self.zoom_combo.addItem(text)
            i = self.zoom_combo.count() - 1
        self.zoom_combo.setCurrentIndex(i)
        self.zoom_combo.blockSignals(False)

    def tile_toggled(self, on: bool):
        self.view_state.tile = on
        self.view_state.changed.emit()

    # --- adopt / scan / build ---

    def adopt(self):
        rels = self.proj.adopt_candidates()
        missing = self.proj.missing_sources()
        if missing:
            QMessageBox.warning(self, "TexLab", "These textures' originals are missing from assets_src/. Their files "
                                "in assets/ are TexLab builds, so they are not offered for adoption. Restore the "
                                "originals instead:\n\n" + "\n".join(missing[:20]))
        if not rels:
            if not missing:
                QMessageBox.information(self, "TexLab",
                                        "Every texture in assets/ already has an original in assets_src/.")
            return
        dlg = AdoptDialog(self, rels)
        if dlg.exec() == QDialog.DialogCode.Accepted and dlg.checked():
            self.proj.adopt(dlg.checked())
            self.proj.save()
            self.build_tree()

    def rescan(self):
        new = self.proj.scan()
        self.src_sizes.clear()
        self.build_tree()
        self.statusBar().showMessage(f"{len(new)} new texture(s)")

    def tree_menu(self, pos):
        missing = [r for r in self.selected_rels() if not os.path.exists(self.proj.src(r))]
        menu = QMenu(self)
        forget = menu.addAction(f"Forget {len(missing)} texture(s) with missing originals")
        forget.setToolTip("Drop their TexLab settings. Their files in assets/ are left alone.")
        forget.setEnabled(bool(missing))
        if menu.exec(self.tree.viewport().mapToGlobal(pos)) != forget:
            return
        if QMessageBox.question(self, "Forget textures",
                                "Drop TexLab's settings for:\n\n" + "\n".join(missing[:20]) +
                                "\n\nTheir built files in assets/ are not deleted (a glTF may still use them)."
                                ) != QMessageBox.StandardButton.Yes:
            return
        self.proj.forget(missing)
        self.proj.save()
        self.build_tree()

    def start_job(self, fn, done):
        job = Job(fn, lambda r: (self.jobs.discard(job), done(r)))
        self.jobs.add(job)
        self.pool.start(job)

    def build_selected(self):
        self.build(self.selected_rels())

    def build_stale(self):
        self.build([r for r in self.proj.textures if self.proj.status(r) in ("stale", "not built")])

    def build_all(self):
        self.build(list(self.proj.textures))

    def build(self, rels: list[str]):
        if self.building:
            self.statusBar().showMessage("A build is already running")
            return
        rels = [r for r in rels if not self.proj.problem(r)]
        if not rels:
            self.statusBar().showMessage("Nothing to build")
            return
        snap = self.proj.snapshot()
        self.building = {r: self.proj.build_key(r) for r in rels}
        self.build_done_count = 0
        self.build_errors = []
        self.statusBar().showMessage(f"Building {len(rels)} texture(s)...")
        for rel in rels:
            # Written next to the output as .tmp (which the engine's watcher ignores), moved into place
            # together at the end so the engine reloads once.
            self.start_job(lambda rel=rel: (rel, P.build(snap, rel, self.proj.out(rel) + ".tmp")), self.built_one)

    def built_one(self, result):
        if isinstance(result, Exception):
            self.build_errors.append(str(result))
        self.build_done_count += 1
        if self.build_done_count < len(self.building):
            self.statusBar().showMessage(f"Building... {self.build_done_count}/{len(self.building)}")
            return
        written = 0
        for rel, key in self.building.items():
            tmp = self.proj.out(rel) + ".tmp"
            if os.path.exists(tmp):
                os.replace(tmp, self.proj.out(rel))
                self.proj.textures[rel].built = key
                written += 1
        self.building = {}
        self.proj.save()
        self.update_rows()
        msg = f"Built {written} texture(s) into assets/"
        if self.build_errors:
            msg += f"; {len(self.build_errors)} failed"
            QMessageBox.warning(self, "TexLab", "Build errors:\n\n" + "\n\n".join(self.build_errors[:5]))
        self.statusBar().showMessage(msg)


def index_image(img: QImage, palette: list[magick.Color]) -> QImage:
    """False-colour view: each palette entry gets a distinct hue."""
    img = img.convertToFormat(QImage.Format.Format_RGBA8888)
    w, h = img.width(), img.height()
    src = bytes(img.constBits())[:w * h * 4]
    lut = {}
    for i, c in enumerate(palette):
        q = QColor.fromHsvF((i * 0.618034) % 1.0, 0.7, 0.95 - 0.4 * (i % 3) / 2)
        lut[bytes(c)] = bytes((q.red(), q.green(), q.blue(), 255))
    out = bytearray(len(src))
    for i in range(0, len(src), 4):
        if src[i + 3]:
            out[i:i + 4] = lut.get(src[i:i + 3], b"\xff\x00\xff\xff")
    return QImage(bytes(out), w, h, w * 4, QImage.Format.Format_RGBA8888).copy()


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    pal = app.palette()
    for role, color in [("Window", "#2b2b2b"), ("WindowText", "#dddddd"), ("Base", "#232323"),
                        ("AlternateBase", "#2b2b2b"), ("Text", "#dddddd"), ("Button", "#353535"),
                        ("ButtonText", "#dddddd"), ("Highlight", "#3d6fa5"), ("HighlightedText", "#ffffff"),
                        ("ToolTipBase", "#353535"), ("ToolTipText", "#dddddd")]:
        pal.setColor(getattr(pal.ColorRole, role), QColor(color))
    app.setPalette(pal)
    win = MainWindow()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
