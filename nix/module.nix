# services.deckpad: a Steam Deck's controls as a Steam Controller for another machine, or the machine that
# plays with them. The module knows nothing about the system it is used in beyond NixOS itself: a host opens
# the port, keeps `statePaths`, and adds the Steam shortcut if it wants one.
{ inputs }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.deckpad;
  programs = import ./package.nix { inherit pkgs inputs; };
  deckpad = "${programs.deckpad}/bin/deckpad";
  trust = lib.concatMapStringsSep " " (line: "--trust ${lib.escapeShellArg line}") cfg.trustedKeys;
  # The service writes its control token once it answers requests.
  awaitService = "${pkgs.coreutils}/bin/timeout 10 ${pkgs.bash}/bin/sh -c 'until [ -e /run/deckpad/token ]; do ${pkgs.coreutils}/bin/sleep 0.1; done'";
  toggle = pkgs.writeShellScriptBin "deckpad-toggle" ''
    if ${pkgs.systemd}/bin/systemctl is-active --quiet deckpad.service; then
      exec ${pkgs.systemd}/bin/systemctl stop deckpad.service
    fi
    ${pkgs.systemd}/bin/systemctl start deckpad.service || exit 1
    # A Deck that trusts no host yet lets the first one pair, so Game Mode
    # needs only this one shortcut.
    ${awaitService} || exit 0
    if ${deckpad} status | ${pkgs.jq}/bin/jq -e '.trusted | length == 0' > /dev/null; then ${deckpad} pairing 120; fi
    # The Deck's screen goes dark and stays so until the service stops. Steam
    # shows the shortcut as running for that long.
    exec ${programs.screen}/bin/deckpad-screen
  '';
  # Start the service if it is not running, then let new hosts pair for two
  # minutes.
  pair = pkgs.writeShellScriptBin "deckpad-pair" ''
    ${pkgs.systemd}/bin/systemctl is-active --quiet deckpad.service || ${pkgs.systemd}/bin/systemctl start deckpad.service
    ${awaitService} || exit 1
    exec ${deckpad} pairing 120
  '';
  tray = pkgs.symlinkJoin {
    name = "deckpad-tray";
    paths = [ programs.tray ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/deckpad-tray \
        --set DECKPAD_TRAY_ICON ${programs.artwork.icon} \
        --prefix PATH : ${lib.makeBinPath [ toggle pair pkgs.systemd pkgs.util-linux ]}
    '';
  };
  # Jovian's power daemon, which tells Steam on the Deck what the charger is.
  # This one says nothing of a slow charger while the service's `usb-host`
  # file exists.
  vpower = pkgs.jovianPackages.vpower.overrideAttrs (old: { patches = (old.patches or []) ++ [ ./vpower-usb-host.patch ]; });
  controller = cfg.enable && cfg.role == "controller";
  host = cfg.enable && cfg.role == "host";
in {
  options.services.deckpad = with lib.types; {
    enable = lib.mkEnableOption "Deck Pad: a Steam Deck's controls as a Steam Controller";
    role = lib.mkOption { type = enum [ "controller" "host" ]; default = "host"; description = "\"controller\" is the Steam Deck offering its controls; \"host\" is the machine that plays with them."; };
    port = lib.mkOption { type = port; default = 3240; description = "The port the controller serves on and the host connects to. The module does not open it."; };
    trustedKeys = lib.mkOption { type = listOf str; default = []; description = "Public keys of the machines on the other side, as OpenSSH lines (`deckpad key` prints a machine's own; its SSH host key by default). Machines listed here never need to pair by hand."; };
    allow = lib.mkOption { type = listOf str; default = []; description = "Controller: the networks hosts may connect from, before any key is checked."; };
    usb = lib.mkOption { type = bool; default = false; description = "Controller: also serve over the USB-C cable. The port must be in device mode: on a Steam Deck, the BIOS option \"USB Dual Role Device\" set to DRD, which also stops the Deck booting from a USB drive."; };
    bluetooth = lib.mkOption { type = bool; default = false; description = "Controller: also serve over Bluetooth. This gives the Deck's adapter the controller's identity and turns off the Deck's own Bluetooth input devices."; };
    controller = lib.mkOption { type = str; default = "steamdeck.local"; description = "Host: where the controller is."; };
    user = lib.mkOption { type = str; description = "The person who uses this machine: may switch the service without a password, and the control token is readable by this user's group."; };
    tray = lib.mkOption { type = bool; default = false; description = "Controller: a switch for the service in the desktop's system tray."; };
    statePaths = lib.mkOption { type = listOf str; readOnly = true; description = "What has to outlive a reinstall or an erased root: trusted keys and, on the Deck, the Bluetooth host to return to."; };
  };

  config = lib.mkMerge [
    { services.deckpad.statePaths = [ "/var/lib/deckpad" ]; }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ programs.deckpad ];
    })

    # The Deck: started on demand, it serves the built-in controls until a stop
    # signal or the two-second ... hold. A host attaching takes the controls.
    (lib.mkIf controller {
      environment.systemPackages = [ toggle pair ];
      # uinput: the pointer that tells the Deck's own session someone is playing.
      boot.kernelModules = [ "uinput" ] ++ lib.optionals cfg.usb [ "libcomposite" "usb_f_fs" ];
      systemd.services.deckpad = {
        description = "Steam Deck controls as a Steam Controller";
        restartIfChanged = false;  # started on demand: a switch must not end a session, and the next start is the new build
        after = [ "jupiter-controller-update.service" ] ++ lib.optional cfg.bluetooth "bluetooth.service";
        wants = lib.optional cfg.bluetooth "bluetooth.service";
        serviceConfig = {
          ExecStart = lib.concatStringsSep " " ([
            "${deckpad} serve --port ${toString cfg.port}"
            (lib.concatMapStringsSep " " (entry: "--allow ${lib.escapeShellArg entry}") cfg.allow)
            trust
          ] ++ lib.optional cfg.usb "--usb" ++ lib.optional cfg.bluetooth "--bluetooth hci0");
          # Whatever happened to the service, the kernel gets the controls and
          # the USB port back.
          ExecStopPost = "${deckpad} release";
          # The control token is for the people who use this machine.
          RuntimeDirectory = "deckpad";
          RuntimeDirectoryMode = "0750";
          StateDirectory = "deckpad";
          StateDirectoryMode = "0700";
          Group = config.users.users.${cfg.user}.group;
          Restart = "on-failure";
          RestartSec = 2;
        };
      };
      # Jovian's firmware check for the Deck's controller runs at boot and on
      # every switch, and talks to the pad this service takes from the kernel.
      # A check in progress holds the service back (`after` above), and while
      # the service runs the check is skipped until the next boot or switch.
      systemd.services.jupiter-controller-update = lib.mkIf (config.jovian.devices.steamdeck.autoUpdate or false) {
        serviceConfig.ExecCondition = "${pkgs.runtimeShell} -c '! ${pkgs.systemd}/bin/systemctl is-active --quiet deckpad.service'";
      };
      # A computer's port charges the Deck slowly, and Steam on the Deck would
      # warn about a slow charger again and again. While a computer holds the
      # controller over the cable, the warning is held back; any other time,
      # and on any other charger, it shows as before.
      systemd.services.vpower = lib.mkIf (cfg.usb && (config.jovian.steam.enable or false)) {
        serviceConfig.ExecStart = [ "" "${vpower}/bin/vpower" ];
      };
      # As a Bluetooth controller the Deck must look like one, and BlueZ's own
      # HID host must not hold the channels a controller serves.
      hardware.bluetooth = lib.mkIf cfg.bluetooth {
        enable = true;
        disabledPlugins = [ "input" ];
        settings.General = { Class = "0x002508"; DeviceID = "usb:28DE:1303:0100"; };
      };
      # The user switches the service without a password, in Game Mode too.
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              action.lookup("unit") == "deckpad.service" && subject.user == "${cfg.user}") {
            return polkit.Result.YES;
          }
        });
      '';
      systemd.user.services.deckpad-tray = lib.mkIf cfg.tray {
        description = "Deck Pad tray switch";
        wantedBy = [ "graphical-session.target" ];
        partOf = [ "graphical-session.target" ];
        after = [ "graphical-session.target" ];
        unitConfig.ConditionUser = cfg.user;
        serviceConfig = {
          ExecStart = "${tray}/bin/deckpad-tray";
          Restart = "on-failure";
          RestartSec = 3;
        };
      };
    })

    # The PC: whenever the Deck offers its controller over the network, hand
    # it to vhci_hcd, which presents it to Steam as a wired Steam Controller.
    # Over the USB-C cable or Bluetooth the PC needs nothing.
    (lib.mkIf host {
      boot.kernelModules = [ "vhci-hcd" ];
      systemd.services.deckpad-attach = {
        description = "Attach the Steam Deck's controller";
        reloadIfChanged = true;  # a switch asks; the service leaves for the new build once no controller is attached
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          # Keys named in the configuration are trusted before the first attach.
          ExecStartPre = map (line: "${deckpad} trust-local ${lib.escapeShellArg line}") cfg.trustedKeys;
          ExecStart = "${deckpad} attach ${lib.escapeShellArg cfg.controller} --port ${toString cfg.port} --watch";
          ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
          ExecStopPost = "${deckpad} detach";
          StateDirectory = "deckpad";
          StateDirectoryMode = "0700";
          Restart = "always";
          RestartSec = 5;
        };
      };
    })
  ];
}
