using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace CodexProxyDesktop
{
    internal static class Ui
    {
        internal static readonly Color Canvas = Color.FromArgb(245, 245, 247);
        internal static readonly Color Sidebar = Color.FromArgb(238, 238, 242);
        internal static readonly Color Surface = Color.White;
        internal static readonly Color Text = Color.FromArgb(29, 29, 31);
        internal static readonly Color SecondaryText = Color.FromArgb(110, 110, 115);
        internal static readonly Color TertiaryText = Color.FromArgb(142, 142, 147);
        internal static readonly Color Separator = Color.FromArgb(218, 218, 223);
        internal static readonly Color SoftFill = Color.FromArgb(235, 235, 240);
        internal static readonly Color Accent = Color.FromArgb(0, 113, 227);
        internal static readonly Color AccentHover = Color.FromArgb(0, 98, 204);
        internal static readonly Color AccentSoft = Color.FromArgb(226, 238, 255);
        internal static readonly Color Success = Color.FromArgb(40, 167, 69);
        internal static readonly Color SuccessSoft = Color.FromArgb(232, 247, 236);
        internal static readonly Color Warning = Color.FromArgb(222, 132, 0);
        internal static readonly Color WarningSoft = Color.FromArgb(255, 245, 224);
        internal static readonly Color Danger = Color.FromArgb(215, 52, 48);
        internal static readonly Color DangerSoft = Color.FromArgb(255, 235, 234);

        private static readonly string BodyFontFamilyName = ResolveFontFamily(new[] { "Microsoft YaHei UI", "Noto Sans SC", "Segoe UI" });
        private static readonly string DisplayFontFamilyName = ResolveFontFamily(new[] { "Microsoft YaHei UI", "Noto Sans SC", "Segoe UI Variable Display", "Segoe UI" });
        private static readonly string LatinFontFamilyName = ResolveFontFamily(new[] { "Segoe UI Variable Display", "Segoe UI", "Microsoft YaHei UI" });

        internal static string ActiveBodyFontFamily { get { return BodyFontFamilyName; } }
        internal static string ActiveDisplayFontFamily { get { return DisplayFontFamilyName; } }

        internal static Font Font(float size, FontStyle style)
        {
            return new Font(BodyFontFamilyName, size, style, GraphicsUnit.Point);
        }

        internal static Font DisplayFont(float size, FontStyle style)
        {
            return new Font(DisplayFontFamilyName, size, style, GraphicsUnit.Point);
        }

        internal static Font LatinFont(float size, FontStyle style)
        {
            return new Font(LatinFontFamilyName, size, style, GraphicsUnit.Point);
        }

        internal static Label Label(string text, float size, FontStyle style, Color color)
        {
            return new Label
            {
                Text = text,
                AutoSize = false,
                Font = Font(size, style),
                ForeColor = color,
                BackColor = Color.Transparent,
                AutoEllipsis = true,
                TextAlign = ContentAlignment.MiddleLeft,
                Margin = Padding.Empty
            };
        }

        internal static void SetCueText(TextBox textBox, string text)
        {
            if (textBox == null || textBox.IsDisposed) return;
            try { SendMessage(textBox.Handle, 0x1501, new IntPtr(1), text); } catch { }
        }

        internal static string CompactPath(string value, int maximumLength)
        {
            if (string.IsNullOrWhiteSpace(value) || value.Length <= maximumLength) return value;
            if (maximumLength < 12) return value.Substring(0, maximumLength);
            int left = Math.Max(4, maximumLength / 2 - 2);
            int right = Math.Max(4, maximumLength - left - 1);
            return value.Substring(0, left) + "…" + value.Substring(value.Length - right);
        }

        internal static GraphicsPath RoundedRectangle(Rectangle bounds, int radius)
        {
            GraphicsPath path = new GraphicsPath();
            int diameter = Math.Max(2, radius * 2);
            Rectangle arc = new Rectangle(bounds.X, bounds.Y, diameter, diameter);
            path.AddArc(arc, 180, 90);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270, 90);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0, 90);
            arc.X = bounds.Left;
            path.AddArc(arc, 90, 90);
            path.CloseFigure();
            return path;
        }

        private static string ResolveFontFamily(string[] candidates)
        {
            foreach (string name in candidates)
            {
                try
                {
                    using (Font font = new Font(name, 9F))
                    {
                        if (string.Equals(font.Name, name, StringComparison.OrdinalIgnoreCase)) return name;
                    }
                }
                catch { }
            }
            return SystemFonts.MessageBoxFont.FontFamily.Name;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
    }

    internal enum AppIconKind
    {
        None,
        Home,
        Sessions,
        Sync,
        Settings,
        Refresh,
        Launch,
        Logs,
        Folder,
        Copy,
        Link,
        Add
    }

    internal static class IconPainter
    {
        internal static void DrawBrandMark(Graphics graphics, Rectangle bounds, Color background)
        {
            if (bounds.Width < 4 || bounds.Height < 4) return;
            GraphicsState state = graphics.Save();
            try
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                float side = Math.Min(bounds.Width, bounds.Height);
                RectangleF square = new RectangleF(bounds.X + (bounds.Width - side) / 2F, bounds.Y + (bounds.Height - side) / 2F, side, side);
                using (GraphicsPath shape = RoundedRectangleF(square, side * 0.28F))
                using (LinearGradientBrush fill = new LinearGradientBrush(square, Lighten(background, 22), background, 45F))
                    graphics.FillPath(fill, shape);

                RectangleF arc = new RectangleF(square.X + side * 0.24F, square.Y + side * 0.22F, side * 0.52F, side * 0.56F);
                using (Pen pen = new Pen(Color.White, Math.Max(1.5F, side * 0.095F)))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    graphics.DrawArc(pen, arc, 47F, 266F);
                }
            }
            finally { graphics.Restore(state); }
        }

        internal static void Draw(Graphics graphics, AppIconKind kind, Rectangle bounds, Color color)
        {
            if (kind == AppIconKind.None || bounds.Width < 4 || bounds.Height < 4) return;
            GraphicsState state = graphics.Save();
            try
            {
                graphics.SmoothingMode = SmoothingMode.AntiAlias;
                graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                float scale = Math.Min(bounds.Width, bounds.Height) / 20F;
                float left = bounds.X + (bounds.Width - 20F * scale) / 2F;
                float top = bounds.Y + (bounds.Height - 20F * scale) / 2F;
                using (Pen pen = new Pen(color, Math.Max(1.35F, 1.65F * scale)))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    pen.LineJoin = LineJoin.Round;
                    if (kind == AppIconKind.Home) DrawHome(graphics, pen, left, top, scale);
                    else if (kind == AppIconKind.Sessions) DrawSessions(graphics, pen, left, top, scale);
                    else if (kind == AppIconKind.Sync || kind == AppIconKind.Refresh) DrawSync(graphics, pen, left, top, scale, kind == AppIconKind.Refresh);
                    else if (kind == AppIconKind.Settings) DrawSettings(graphics, pen, left, top, scale);
                    else if (kind == AppIconKind.Launch) DrawLaunch(graphics, pen, left, top, scale);
                    else if (kind == AppIconKind.Logs) DrawLogs(graphics, pen, left, top, scale);
                    else if (kind == AppIconKind.Folder) DrawFolder(graphics, pen, left, top, scale);
                    else if (kind == AppIconKind.Copy) DrawCopy(graphics, pen, left, top, scale);
                    else if (kind == AppIconKind.Link) DrawLink(graphics, pen, left, top, scale);
                    else if (kind == AppIconKind.Add) DrawAdd(graphics, pen, left, top, scale);
                }
            }
            finally { graphics.Restore(state); }
        }

        private static void DrawHome(Graphics g, Pen p, float x, float y, float s)
        {
            PointF[] roof = { P(x, y, s, 3.2F, 9F), P(x, y, s, 10F, 3.5F), P(x, y, s, 16.8F, 9F) };
            g.DrawLines(p, roof);
            g.DrawLine(p, P(x, y, s, 5F, 8F), P(x, y, s, 5F, 16.3F));
            g.DrawLine(p, P(x, y, s, 15F, 8F), P(x, y, s, 15F, 16.3F));
            g.DrawLine(p, P(x, y, s, 5F, 16.3F), P(x, y, s, 15F, 16.3F));
            g.DrawLine(p, P(x, y, s, 8.1F, 16.2F), P(x, y, s, 8.1F, 11.7F));
        }

        private static void DrawSessions(Graphics g, Pen p, float x, float y, float s)
        {
            using (GraphicsPath back = RoundedRectangleF(R(x, y, s, 5.2F, 3.4F, 11.4F, 12.1F), 2.1F * s)) g.DrawPath(p, back);
            using (GraphicsPath front = RoundedRectangleF(R(x, y, s, 3.3F, 5.4F, 11.4F, 11.3F), 2.1F * s)) g.DrawPath(p, front);
            g.DrawLine(p, P(x, y, s, 6.2F, 9.4F), P(x, y, s, 11.8F, 9.4F));
            g.DrawLine(p, P(x, y, s, 6.2F, 12.6F), P(x, y, s, 9.9F, 12.6F));
        }

        private static void DrawSync(Graphics g, Pen p, float x, float y, float s, bool compact)
        {
            RectangleF ring = R(x, y, s, 3.4F, 3.4F, 13.2F, 13.2F);
            g.DrawArc(p, ring, 202F, compact ? 250F : 132F);
            g.DrawArc(p, ring, 22F, compact ? 0F : 132F);
            g.DrawLines(p, new[] { P(x, y, s, 3.1F, 6.3F), P(x, y, s, 3.5F, 3.2F), P(x, y, s, 6.6F, 3.9F) });
            if (!compact) g.DrawLines(p, new[] { P(x, y, s, 16.9F, 13.7F), P(x, y, s, 16.5F, 16.8F), P(x, y, s, 13.4F, 16.1F) });
        }

        private static void DrawSettings(Graphics g, Pen p, float x, float y, float s)
        {
            g.DrawLine(p, P(x, y, s, 3.3F, 5.2F), P(x, y, s, 16.7F, 5.2F));
            g.DrawLine(p, P(x, y, s, 3.3F, 10F), P(x, y, s, 16.7F, 10F));
            g.DrawLine(p, P(x, y, s, 3.3F, 14.8F), P(x, y, s, 16.7F, 14.8F));
            DrawKnob(g, p, x, y, s, 7F, 5.2F);
            DrawKnob(g, p, x, y, s, 13F, 10F);
            DrawKnob(g, p, x, y, s, 8.8F, 14.8F);
        }

        private static void DrawLaunch(Graphics g, Pen p, float x, float y, float s)
        {
            using (GraphicsPath path = new GraphicsPath())
            {
                path.AddLine(P(x, y, s, 7F, 4.1F), P(x, y, s, 15.7F, 10F));
                path.AddLine(P(x, y, s, 15.7F, 10F), P(x, y, s, 7F, 15.9F));
                path.CloseFigure();
                g.DrawPath(p, path);
            }
        }

        private static void DrawLogs(Graphics g, Pen p, float x, float y, float s)
        {
            using (GraphicsPath page = RoundedRectangleF(R(x, y, s, 4.2F, 2.9F, 11.6F, 14.2F), 1.8F * s)) g.DrawPath(p, page);
            g.DrawLine(p, P(x, y, s, 7F, 7F), P(x, y, s, 13F, 7F));
            g.DrawLine(p, P(x, y, s, 7F, 10.2F), P(x, y, s, 13F, 10.2F));
            g.DrawLine(p, P(x, y, s, 7F, 13.4F), P(x, y, s, 11F, 13.4F));
        }

        private static void DrawFolder(Graphics g, Pen p, float x, float y, float s)
        {
            using (GraphicsPath path = new GraphicsPath())
            {
                path.AddLine(P(x, y, s, 3F, 6F), P(x, y, s, 7.4F, 6F));
                path.AddLine(P(x, y, s, 7.4F, 6F), P(x, y, s, 9F, 8F));
                path.AddLine(P(x, y, s, 9F, 8F), P(x, y, s, 17F, 8F));
                path.AddLine(P(x, y, s, 17F, 8F), P(x, y, s, 16F, 16F));
                path.AddLine(P(x, y, s, 16F, 16F), P(x, y, s, 4F, 16F));
                path.CloseFigure();
                g.DrawPath(p, path);
            }
        }

        private static void DrawCopy(Graphics g, Pen p, float x, float y, float s)
        {
            using (GraphicsPath back = RoundedRectangleF(R(x, y, s, 6F, 3.5F, 10F, 10F), 1.8F * s)) g.DrawPath(p, back);
            using (GraphicsPath front = RoundedRectangleF(R(x, y, s, 3.5F, 6F, 10F, 10F), 1.8F * s)) g.DrawPath(p, front);
        }

        private static void DrawLink(Graphics g, Pen p, float x, float y, float s)
        {
            g.DrawArc(p, R(x, y, s, 2.9F, 5.1F, 9.2F, 9.2F), 42F, 276F);
            g.DrawArc(p, R(x, y, s, 7.9F, 5.7F, 9.2F, 9.2F), 222F, 276F);
            g.DrawLine(p, P(x, y, s, 7.2F, 10F), P(x, y, s, 12.8F, 10F));
        }

        private static void DrawAdd(Graphics g, Pen p, float x, float y, float s)
        {
            g.DrawEllipse(p, R(x, y, s, 3.4F, 3.4F, 13.2F, 13.2F));
            g.DrawLine(p, P(x, y, s, 10F, 6.8F), P(x, y, s, 10F, 13.2F));
            g.DrawLine(p, P(x, y, s, 6.8F, 10F), P(x, y, s, 13.2F, 10F));
        }

        private static void DrawKnob(Graphics g, Pen p, float x, float y, float s, float px, float py)
        {
            using (SolidBrush fill = new SolidBrush(Color.White)) g.FillEllipse(fill, R(x, y, s, px - 1.55F, py - 1.55F, 3.1F, 3.1F));
            g.DrawEllipse(p, R(x, y, s, px - 1.55F, py - 1.55F, 3.1F, 3.1F));
        }

        private static PointF P(float x, float y, float s, float px, float py) { return new PointF(x + px * s, y + py * s); }
        private static RectangleF R(float x, float y, float s, float px, float py, float width, float height) { return new RectangleF(x + px * s, y + py * s, width * s, height * s); }

        private static GraphicsPath RoundedRectangleF(RectangleF bounds, float radius)
        {
            GraphicsPath path = new GraphicsPath();
            float diameter = Math.Max(2F, radius * 2F);
            RectangleF arc = new RectangleF(bounds.X, bounds.Y, diameter, diameter);
            path.AddArc(arc, 180F, 90F);
            arc.X = bounds.Right - diameter;
            path.AddArc(arc, 270F, 90F);
            arc.Y = bounds.Bottom - diameter;
            path.AddArc(arc, 0F, 90F);
            arc.X = bounds.Left;
            path.AddArc(arc, 90F, 90F);
            path.CloseFigure();
            return path;
        }

        private static Color Lighten(Color color, int amount)
        {
            return Color.FromArgb(color.A, Math.Min(255, color.R + amount), Math.Min(255, color.G + amount), Math.Min(255, color.B + amount));
        }
    }

    internal sealed class BrandMark : Control
    {
        internal Color Accent = Ui.Accent;

        internal BrandMark()
        {
            Size = new Size(36, 36);
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            BackColor = Color.Transparent;
            AccessibleRole = AccessibleRole.Graphic;
            AccessibleName = "Codex Proxy";
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            IconPainter.DrawBrandMark(e.Graphics, new Rectangle(0, 0, Width, Height), Accent);
        }
    }

    internal sealed class RoundedPanel : Panel
    {
        internal int Radius = 16;
        internal Color BorderColor = Ui.Separator;
        internal bool DrawBorder = true;

        internal RoundedPanel()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Ui.Surface;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
            using (GraphicsPath path = Ui.RoundedRectangle(bounds, Radius))
            using (SolidBrush brush = new SolidBrush(BackColor))
            {
                e.Graphics.FillPath(brush, path);
                if (DrawBorder)
                {
                    using (Pen pen = new Pen(BorderColor)) e.Graphics.DrawPath(pen, path);
                }
            }
            base.OnPaint(e);
        }
    }

    internal enum AppButtonStyle
    {
        Primary,
        Secondary,
        Ghost,
        Danger
    }

    internal sealed class AppButton : Control
    {
        private bool hovering;
        private bool pressed;
        private AppButtonStyle style;
        internal AppIconKind IconKind = AppIconKind.None;

        internal AppButtonStyle Style
        {
            get { return style; }
            set { style = value; Invalidate(); }
        }

        internal AppButton()
        {
            Cursor = Cursors.Hand;
            Font = Ui.Font(9F, FontStyle.Bold);
            Height = 36;
            TabStop = true;
            AccessibleRole = AccessibleRole.PushButton;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnMouseEnter(EventArgs e) { hovering = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hovering = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { pressed = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { pressed = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Cursor = Enabled ? Cursors.Hand : Cursors.Default; Invalidate(); base.OnEnabledChanged(e); }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Space || keyData == Keys.Enter) return true;
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter)
            {
                OnClick(EventArgs.Empty);
                e.Handled = true;
            }
            base.OnKeyDown(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Color background;
            Color foreground;
            Color border;
            if (!Enabled)
            {
                background = Color.FromArgb(229, 229, 234);
                foreground = Ui.TertiaryText;
                border = background;
            }
            else if (Style == AppButtonStyle.Primary)
            {
                background = pressed ? Color.FromArgb(0, 84, 180) : (hovering ? Ui.AccentHover : Ui.Accent);
                foreground = Color.White;
                border = background;
            }
            else if (Style == AppButtonStyle.Danger)
            {
                background = pressed ? Color.FromArgb(244, 215, 213) : (hovering ? Ui.DangerSoft : Color.Transparent);
                foreground = Ui.Danger;
                border = Style == AppButtonStyle.Ghost ? Color.Transparent : Ui.Separator;
            }
            else if (Style == AppButtonStyle.Ghost)
            {
                background = pressed ? Color.FromArgb(220, 220, 225) : (hovering ? Ui.SoftFill : Color.Transparent);
                foreground = Ui.Text;
                border = Color.Transparent;
            }
            else
            {
                background = pressed ? Color.FromArgb(214, 214, 219) : (hovering ? Color.FromArgb(225, 225, 230) : Ui.SoftFill);
                foreground = Ui.Text;
                border = background;
            }

            Rectangle bounds = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
            using (GraphicsPath path = Ui.RoundedRectangle(bounds, 9))
            using (SolidBrush brush = new SolidBrush(background))
            using (Pen pen = new Pen(border))
            {
                e.Graphics.FillPath(brush, path);
                if (border != Color.Transparent) e.Graphics.DrawPath(pen, path);
            }
            if (IconKind == AppIconKind.None)
            {
                TextRenderer.DrawText(e.Graphics, Text, Font, bounds, foreground, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            }
            else
            {
                Size measured = TextRenderer.MeasureText(e.Graphics, Text, Font, new Size(Math.Max(1, bounds.Width - 38), bounds.Height), TextFormatFlags.NoPadding | TextFormatFlags.SingleLine);
                int iconSize = 17;
                int gap = 7;
                int totalWidth = Math.Min(bounds.Width - 12, iconSize + gap + measured.Width);
                int startX = bounds.X + Math.Max(6, (bounds.Width - totalWidth) / 2);
                Rectangle iconBounds = new Rectangle(startX, bounds.Y + (bounds.Height - iconSize) / 2, iconSize, iconSize);
                Rectangle textBounds = new Rectangle(iconBounds.Right + gap, bounds.Y, Math.Max(1, bounds.Right - iconBounds.Right - gap - 5), bounds.Height);
                IconPainter.Draw(e.Graphics, IconKind, iconBounds, foreground);
                TextRenderer.DrawText(e.Graphics, Text, Font, textBounds, foreground, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPadding);
            }
            if (Focused && ShowFocusCues)
            {
                Rectangle focus = Rectangle.Inflate(bounds, -4, -4);
                ControlPaint.DrawFocusRectangle(e.Graphics, focus, foreground, background);
            }
        }
    }

    internal sealed class NavigationButton : Control
    {
        private bool selected;
        private bool compact;
        private bool hovering;
        internal AppIconKind IconKind = AppIconKind.Home;

        internal bool Selected
        {
            get { return selected; }
            set { selected = value; Invalidate(); }
        }

        internal bool Compact
        {
            get { return compact; }
            set { compact = value; Invalidate(); }
        }

        internal NavigationButton()
        {
            BackColor = Ui.Sidebar;
            Cursor = Cursors.Hand;
            Height = 42;
            Font = Ui.Font(9.5F, FontStyle.Bold);
            TabStop = true;
            AccessibleRole = AccessibleRole.PushButton;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnMouseEnter(EventArgs e) { hovering = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hovering = false; Invalidate(); base.OnMouseLeave(e); }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Space || keyData == Keys.Enter) return true;
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space || e.KeyCode == Keys.Enter)
            {
                OnClick(EventArgs.Empty);
                e.Handled = true;
            }
            base.OnKeyDown(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(2, 1, Math.Max(1, Width - 5), Math.Max(1, Height - 3));
            Color fill = Selected ? Color.FromArgb(219, 231, 248) : (hovering ? Color.FromArgb(228, 228, 233) : Color.Transparent);
            if (fill != Color.Transparent)
            {
                using (GraphicsPath path = Ui.RoundedRectangle(bounds, 10))
                using (SolidBrush brush = new SolidBrush(fill)) e.Graphics.FillPath(brush, path);
            }
            Color color = Selected ? Ui.Accent : Ui.Text;
            Rectangle glyphBounds = Compact ? new Rectangle(bounds.X + (bounds.Width - 20) / 2, bounds.Y + (bounds.Height - 20) / 2, 20, 20) : new Rectangle(bounds.X + 14, bounds.Y + (bounds.Height - 19) / 2, 19, 19);
            if (Compact) IconPainter.Draw(e.Graphics, IconKind, glyphBounds, color);
            else
            {
                IconPainter.Draw(e.Graphics, IconKind, glyphBounds, color);
                Rectangle textBounds = new Rectangle(bounds.X + 45, bounds.Y, Math.Max(1, bounds.Width - 55), bounds.Height);
                TextRenderer.DrawText(e.Graphics, Text, Font, textBounds, color, TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
            }
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(bounds, -3, -3), color, fill == Color.Transparent ? Ui.Sidebar : fill);
        }
    }

    internal sealed class ToggleSwitch : Control
    {
        private bool checkedValue;

        internal bool Checked
        {
            get { return checkedValue; }
            set
            {
                if (checkedValue == value) return;
                checkedValue = value;
                Invalidate();
                if (CheckedChanged != null) CheckedChanged(this, EventArgs.Empty);
            }
        }

        internal event EventHandler CheckedChanged;

        internal ToggleSwitch()
        {
            Size = new Size(44, 24);
            Cursor = Cursors.Hand;
            TabStop = true;
            AccessibleRole = AccessibleRole.CheckButton;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnClick(EventArgs e)
        {
            Checked = !Checked;
            base.OnClick(e);
        }

        protected override bool IsInputKey(Keys keyData)
        {
            if (keyData == Keys.Space) return true;
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Space)
            {
                Checked = !Checked;
                e.Handled = true;
            }
            base.OnKeyDown(e);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle track = new Rectangle(1, 2, Width - 3, Height - 5);
            using (GraphicsPath path = Ui.RoundedRectangle(track, track.Height / 2))
            using (SolidBrush brush = new SolidBrush(Checked ? Ui.Accent : Color.FromArgb(190, 190, 195))) e.Graphics.FillPath(brush, path);
            int diameter = track.Height - 4;
            int x = Checked ? track.Right - diameter - 2 : track.Left + 2;
            using (SolidBrush knob = new SolidBrush(Color.White)) e.Graphics.FillEllipse(knob, x, track.Top + 2, diameter, diameter);
            if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, ClientRectangle, Ui.Accent, Ui.Surface);
        }
    }

    internal sealed class PillLabel : Control
    {
        private Color accent = Ui.TertiaryText;
        private Color fill = Ui.SoftFill;

        internal Color Accent
        {
            get { return accent; }
            set { accent = value; Invalidate(); }
        }

        internal Color Fill
        {
            get { return fill; }
            set { fill = value; Invalidate(); }
        }

        internal PillLabel()
        {
            Font = Ui.Font(8.5F, FontStyle.Bold);
            Height = 26;
            Width = 100;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            Rectangle bounds = new Rectangle(0, 0, Math.Max(1, Width - 1), Math.Max(1, Height - 1));
            using (GraphicsPath path = Ui.RoundedRectangle(bounds, Height / 2))
            using (SolidBrush brush = new SolidBrush(Fill)) e.Graphics.FillPath(brush, path);
            TextRenderer.DrawText(e.Graphics, Text, Font, bounds, Accent, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }

    internal sealed class BufferedListView : ListView
    {
        internal BufferedListView()
        {
            DoubleBuffered = true;
            BorderStyle = BorderStyle.None;
            BackColor = Ui.Surface;
            ForeColor = Ui.Text;
            Font = Ui.Font(9F, FontStyle.Regular);
            View = View.Details;
            FullRowSelect = true;
            HideSelection = false;
            MultiSelect = false;
            GridLines = false;
        }
    }
}
