using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

// .NET Framework / Windows Forms: no browser engine or downloaded UI runtime.
internal sealed class RelaySetup : Form
{
    readonly string root = AppDomain.CurrentDomain.BaseDirectory;
    readonly JavaScriptSerializer json = new JavaScriptSerializer();
    readonly TabControl tabs = new TabControl { Dock = DockStyle.Fill };
    readonly TextBox log = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, Dock = DockStyle.Fill, WordWrap = false };
    readonly Label state = new Label { Dock = DockStyle.Bottom, Height = 28, Text = "Ready", Padding = new Padding(8, 5, 0, 0) };
    readonly NumericUpDown port = new NumericUpDown { Minimum = 1, Maximum = 65535, Value = 8787, Width = 120 };
    readonly ComboBox network = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 420 };
    readonly TextBox url = new TextBox { Text = "http://127.0.0.1:8787", Width = 420 };
    readonly TextBox hostname = new TextBox { Width = 420 };
    readonly TextBox tunnelName = new TextBox { Width = 420, Text = "relay-windows" };
    readonly TextBox label = new TextBox { Width = 420, Text = "Windows device" };
    readonly TextBox password = new TextBox { Width = 280, UseSystemPasswordChar = true };
    readonly TextBox confirm = new TextBox { Width = 280, UseSystemPasswordChar = true };
    readonly CheckBox web = new CheckBox { Text = "Serve the bundled Web client at the backend address", AutoSize = true, Checked = true };
    readonly CheckBox overwrite = new CheckBox { Text = "Replace an existing Cloudflare DNS record if necessary", AutoSize = true };
    readonly CheckedListBox agents = new CheckedListBox { Height = 125, Width = 760, CheckOnClick = true, HorizontalScrollbar = true };
    readonly DataGridView tokens = new DataGridView { Dock = DockStyle.Fill, ReadOnly = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false, MultiSelect = false, SelectionMode = DataGridViewSelectionMode.FullRowSelect, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill, RowHeadersVisible = false };
    readonly Label summary = new Label { AutoSize = true, MaximumSize = new Size(730, 0), Text = "Click Refresh status to read this installation." };
    readonly CheckBox removeWeb = new CheckBox { Text = "Remove the bundled Web client", AutoSize = true, Checked = true };
    readonly CheckBox deleteTunnel = new CheckBox { Text = "Delete this named tunnel from my Cloudflare account", AutoSize = true };
    readonly CheckBox removeCloudflared = new CheckBox { Text = "Remove cloudflared downloaded by this bundle", AutoSize = true };
    readonly List<Button> buttons = new List<Button>();
    readonly string[] keys = { "claude", "codex", "cursor", "opencode", "hermes" };
    readonly string[] names = { "Claude Code", "Codex", "Cursor", "OpenCode", "Hermes" };
    bool busy;
    bool loaded;
    string currentUrl = "";

    [STAThread]
    static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new RelaySetup());
    }

    RelaySetup()
    {
        Text = "Relay Backend Setup";
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 10);
        MinimumSize = new Size(850, 720);
        Size = new Size(980, 900);
        StartPosition = FormStartPosition.CenterScreen;
        var split = new SplitContainer { Size = new Size(960, 820), Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, SplitterDistance = 590 };
        Controls.Add(split); Controls.Add(state);
        split.Panel1.Controls.Add(tabs);
        split.Panel2.Controls.Add(log);
        log.Font = new Font("Consolas", 9);
        var install = Page("Install / Reinstall");
        Heading(install, "1. System software and server dependencies");
        Note(install, "Extract the complete bundle to a permanent writable folder. Node.js, npm and backend packages are included; no separate Web server is needed.");
        Note(install, "Installation folder: " + root);
        Heading(install, "2. Agent CLIs (optional)");
        for (int i = 0; i < names.Length; i++) agents.Items.Add(names[i] + " - checking...");
        install.Controls.Add(agents);
        Note(install, "Select missing CLIs to download from their official publishers. Sign in yourself afterward; existing CLI accounts stay on this host.");
        Heading(install, "3. Web client"); install.Controls.Add(web);
        Heading(install, "4. Network");
        network.Items.AddRange(new object[] { "Direct address / no tunnel", "Named Cloudflare Tunnel / stable hostname", "Cloudflare Quick Tunnel / temporary URL" });
        network.SelectedIndex = 2;
        Row(install, "Backend port", port); Row(install, "Network mode", network);
        Row(install, "Direct public URL", url); Row(install, "Cloudflare hostname", hostname);
        Row(install, "Tunnel name", tunnelName); install.Controls.Add(overwrite);
        Note(install, "Tunnel modes install cloudflared if missing. Named tunnels open a Cloudflare browser login. Quick Tunnel addresses can change after restart. Direct access needs a reachable port; use HTTPS for public access.");
        Heading(install, "5. Device credential");
        Row(install, "Device label", label); Row(install, "New QR password (6+ characters)", password); Row(install, "Confirm password", confirm);
        Note(install, "Import the encrypted .relay.json or .relay.png from server/credentials. Reinstall keeps tokens, chats and settings and creates a new device credential.");
        var installButtons = new FlowLayoutPanel { AutoSize = true };
        Button(installButtons, "Install", async delegate { await Install(false); });
        Button(installButtons, "Reinstall (keep data)", async delegate { if (Ask("Stop Relay and reconfigure this installation? Tokens, chats and settings will be kept.")) await Install(true); });
        Button(installButtons, "Install selected CLIs", async delegate { await Run("agents", Request()); });
        install.Controls.Add(installButtons);
        network.SelectedIndexChanged += delegate { NetworkFields(); };
        NetworkFields();

        var services = Page("Services / Uninstall");
        Heading(services, "Service status"); services.Controls.Add(summary);
        var serviceButtons = new FlowLayoutPanel { AutoSize = true };
        Button(serviceButtons, "Refresh status", async delegate { await Run("status", Request()); });
        Button(serviceButtons, "Start", async delegate { await Run("start", Request()); });
        Button(serviceButtons, "Stop", async delegate { await Run("stop", Request()); });
        Button(serviceButtons, "Open Web client", delegate { Open(currentUrl); });
        Button(serviceButtons, "Open logs", delegate { Open(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Relay", "logs")); });
        services.Controls.Add(serviceButtons);
        Note(services, "Services run as this Windows user. Setup registers a task at login. Keep this installation folder fixed so the task can find it.");
        Heading(services, "Uninstall all Relay services");
        services.Controls.Add(removeWeb); services.Controls.Add(deleteTunnel); services.Controls.Add(removeCloudflared);
        Note(services, "Configuration, tokens, encrypted credentials, chats, settings and logs are retained. Other host software and agent CLIs are retained. Extract the release again to restore a removed Web client.");
        Button(services, "Uninstall services", async delegate {
            if (!Ask("Stop Relay and remove its login task and the selected components?")) return;
            var request = Request(); request["removeWeb"] = removeWeb.Checked;
            request["deleteTunnel"] = deleteTunnel.Checked; request["removeCloudflared"] = removeCloudflared.Checked;
            await Run("uninstall", request);
        });

        var tokenPage = new TabPage("Device tokens"); tabs.TabPages.Add(tokenPage);
        var tokenLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 3, Padding = new Padding(10) };
        tokenPage.Controls.Add(tokenLayout);
        tokenLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); tokenLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); tokenLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        tokenLayout.Controls.Add(new Label { AutoSize = true, MaximumSize = new Size(800, 0), Text = "Create, delete, list or re-show a device token, like Linux setup. Set the label and password on Install / Reinstall before creating or re-showing a credential. Re-showing keeps the token and sets a new QR password." });
        foreach (string field in new[] { "ID", "Label", "State", "Last used" }) tokens.Columns.Add(field, field);
        tokenLayout.Controls.Add(tokens);
        var tokenButtons = new FlowLayoutPanel { AutoSize = true };
        Button(tokenButtons, "List / Refresh", async delegate { await Run("status", Request()); });
        Button(tokenButtons, "Create new token", async delegate { await Token(false); });
        Button(tokenButtons, "Show credential again", async delegate { await Token(true); });
        Button(tokenButtons, "Delete selected token", async delegate {
            var id = SelectedToken(); if (id == null || !Ask("Delete this token? Devices using it will lose access.")) return;
            var request = Request(); request["tokenId"] = id; await Run("delete-token", request);
        });
        Button(tokenButtons, "Open credential folder", delegate { Open(Path.Combine(root, "server", "credentials")); });
        Button(tokenButtons, "View latest QR", delegate { ShowQr(); });
        tokenLayout.Controls.Add(tokenButtons);
        Shown += async delegate { await Run("status", Request()); };
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (busy) { e.Cancel = true; MessageBox.Show(this, "Wait for the current operation to finish before closing Setup.", Text); }
        };
    }

    FlowLayoutPanel Page(string title)
    {
        var page = new TabPage(title); tabs.TabPages.Add(page);
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(16) };
        page.Controls.Add(panel); return panel;
    }
    static void Heading(Control parent, string text) { parent.Controls.Add(new Label { Text = text, AutoSize = true, Font = new Font("Segoe UI", 11, FontStyle.Bold), Margin = new Padding(0, 14, 0, 6) }); }
    static void Note(Control parent, string text) { parent.Controls.Add(new Label { Text = text, AutoSize = true, MaximumSize = new Size(790, 0), Margin = new Padding(0, 5, 0, 8) }); }
    static void Row(Control parent, string text, Control input)
    {
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        row.Controls.Add(new Label { Text = text, Width = 270, Height = 30, TextAlign = ContentAlignment.MiddleLeft });
        row.Controls.Add(input); parent.Controls.Add(row);
    }
    void Button(Control parent, string text, EventHandler handler)
    {
        var button = new Button { Text = text, AutoSize = true, MinimumSize = new Size(90, 34), Margin = new Padding(0, 6, 8, 6) };
        button.Click += handler; parent.Controls.Add(button); buttons.Add(button);
    }
    bool Ask(string text) { return MessageBox.Show(this, text, Text, MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes; }
    void Open(string target)
    {
        if (String.IsNullOrWhiteSpace(target)) { MessageBox.Show(this, "No address or folder is available yet.", Text); return; }
        Uri uri;
        if (Uri.TryCreate(target, UriKind.Absolute, out uri) && !uri.IsFile && uri.Scheme != "http" && uri.Scheme != "https") return;
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception error) { MessageBox.Show(this, error.Message, Text); }
    }
    void NetworkFields() { url.Enabled = network.SelectedIndex == 0; hostname.Enabled = tunnelName.Enabled = overwrite.Enabled = network.SelectedIndex == 1; }
    Dictionary<string, object> Request()
    {
        var selected = new List<string>();
        for (int i = 0; i < keys.Length; i++) if (agents.GetItemChecked(i)) selected.Add(keys[i]);
        return new Dictionary<string, object> {
            { "port", (int)port.Value }, { "networkMode", new[] { "none", "cloudflare", "quick" }[network.SelectedIndex] },
            { "url", url.Text.Trim() }, { "hostname", hostname.Text.Trim() }, { "tunnelName", tunnelName.Text.Trim() },
            { "serveWeb", web.Checked }, { "agents", selected }, { "passphrase", password.Text },
            { "label", label.Text.Trim() }, { "overwriteDns", overwrite.Checked }
        };
    }
    bool PasswordValid()
    {
        if (password.Text.Length >= 6 && password.Text == confirm.Text) return true;
        MessageBox.Show(this, "Enter matching credential passwords of at least 6 characters on Install / Reinstall.", Text);
        tabs.SelectedIndex = 0; password.Focus(); return false;
    }
    async Task Install(bool reinstall) { if (PasswordValid()) await Run(reinstall ? "reinstall" : "install", Request()); }
    string SelectedToken()
    {
        if (tokens.SelectedRows.Count > 0) return Convert.ToString(tokens.SelectedRows[0].Cells[0].Value);
        MessageBox.Show(this, "Select a device token first.", Text); return null;
    }
    async Task Token(bool show)
    {
        var id = show ? SelectedToken() : ""; if (id == null || !PasswordValid()) return;
        var request = Request(); request["url"] = currentUrl; request["tokenId"] = id;
        if (String.IsNullOrWhiteSpace(currentUrl)) { MessageBox.Show(this, "Install Relay or refresh its status first.", Text); return; }
        await Run(show ? "show-token" : "create-token", request);
    }
    void Append(string line) { if (!String.IsNullOrEmpty(line)) log.AppendText(line + Environment.NewLine); }
    void ShowQr()
    {
        var directory = Path.Combine(root, "server", "credentials");
        if (!Directory.Exists(directory)) return;
        var files = new DirectoryInfo(directory).GetFiles("*.relay.png");
        if (files.Length == 0) return;
        Array.Sort(files, delegate(FileInfo a, FileInfo b) { return b.LastWriteTimeUtc.CompareTo(a.LastWriteTimeUtc); });
        using (var preview = new Form { Text = "Encrypted device credential", Size = new Size(600, 660), StartPosition = FormStartPosition.CenterParent })
        using (var image = Image.FromFile(files[0].FullName)) {
            preview.Controls.Add(new PictureBox { Dock = DockStyle.Fill, Image = image, SizeMode = PictureBoxSizeMode.Zoom });
            preview.Controls.Add(new Label { Dock = DockStyle.Bottom, Height = 65, Padding = new Padding(12), Text = "Scan this QR in Relay and enter the password you chose. You can also import the encrypted .relay.json file from server/credentials." });
            preview.ShowDialog(this);
        }
    }
    void ApplyResult(string value)
    {
        var data = json.Deserialize<Dictionary<string, object>>(value);
        currentUrl = Convert.ToString(data["url"]);
        summary.Text = String.Format("Backend: {0}    Tunnel: {1}\nAddress: {2}\nMode: {3}    Port: {4}\nWeb client: {5}\nLogs: {6}",
            (bool)data["backendRunning"] ? "running" : "stopped", (bool)data["tunnelRunning"] ? "running" : "stopped", currentUrl,
            data["networkMode"], data["port"], !(bool)data["webAvailable"] ? "not present" : (bool)data["serveWeb"] ? "enabled" : "disabled", data["logs"]);
        var array = (ArrayList)data["agents"];
        for (int i = 0; i < array.Count; i++) {
            var agent = (Dictionary<string, object>)array[i];
            agents.Items[i] = agent["label"] + " - " + (!(bool)agent["installed"] ? "not installed" : (bool)agent["authed"] ? "ready" : "installed, sign in/configure on this host") + " | " + agent["login"];
        }
        tokens.Rows.Clear();
        foreach (Dictionary<string, object> token in (ArrayList)data["tokens"]) {
            tokens.Rows.Add(token["id"], token["label"], (bool)token["revoked"] ? "revoked" : "active", token.ContainsKey("lastUsedAt") ? token["lastUsedAt"] : "never");
        }
        if (!loaded) {
            loaded = true;
            if (!String.IsNullOrWhiteSpace(currentUrl)) url.Text = currentUrl;
            int savedPort; if (Int32.TryParse(Convert.ToString(data["port"]), out savedPort) && savedPort > 0 && savedPort <= 65535) port.Value = savedPort;
            var mode = Convert.ToString(data["networkMode"]);
            if (mode == "none" || mode == "cloudflare" || mode == "quick") network.SelectedIndex = Array.IndexOf(new[] { "none", "cloudflare", "quick" }, mode);
            web.Checked = (bool)data["serveWeb"] && (bool)data["webAvailable"];
            var savedTunnel = Convert.ToString(data["tunnelName"]); if (savedTunnel.Length > 0) tunnelName.Text = savedTunnel;
            Uri address; if (Uri.TryCreate(currentUrl, UriKind.Absolute, out address)) hostname.Text = address.Host;
        }
        Append(summary.Text);
    }
    async Task Run(string action, Dictionary<string, object> request)
    {
        if (busy) return;
        busy = true; foreach (var button in buttons) button.Enabled = false;
        state.Text = "Running: " + action; request["action"] = action;
        string result = null;
        try {
            var worker = Path.Combine(root, "scripts", "install", "windows", "setup-action.ps1");
            if (!File.Exists(worker)) throw new FileNotFoundException("Keep Setup.exe with the complete extracted backend bundle.", worker);
            var start = new ProcessStartInfo {
                FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + worker + "\"",
                WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            int exitCode = await Task.Run(delegate {
                using (var process = new Process { StartInfo = start }) {
                    process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                        if (e.Data == null) return;
                        if (e.Data.StartsWith("RELAY_RESULT:", StringComparison.Ordinal)) result = e.Data.Substring(13);
                        else BeginInvoke((Action)delegate { Append(e.Data); });
                    };
                    process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) BeginInvoke((Action)delegate { Append(e.Data); }); };
                    process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
                    byte[] payload = new UTF8Encoding(false).GetBytes(json.Serialize(request));
                    process.StandardInput.BaseStream.Write(payload, 0, payload.Length); process.StandardInput.Close();
                    process.WaitForExit(); return process.ExitCode;
                }
            });
            if (exitCode != 0) throw new InvalidOperationException("Operation failed. See the output below for details, correct the issue and retry.");
            if (result != null) ApplyResult(result);
            state.Text = "Completed: " + action;
            if (action == "install" || action == "reinstall" || action == "create-token" || action == "show-token") {
                password.Clear(); confirm.Clear();
                Append("Encrypted credential files are in " + Path.Combine(root, "server", "credentials"));
            }
        } catch (Exception error) { state.Text = "Failed: " + action; Append(error.Message); MessageBox.Show(this, error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error); }
        finally { request.Remove("passphrase"); busy = false; foreach (var button in buttons) button.Enabled = true; }
    }
}
