{
  description = "Shared scoped-Claude-Code-agent harness (guard, hooks, managed settings)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in
    {
      nixosModules.agent = import ./modules;
      nixosModules.default = self.nixosModules.agent;

      # secret-put — the one way to hand a secret to a host. Deliberately a
      # separate module from `agent`: hosts with no agent on them want it too,
      # and importing it must not pull in a guard. Why and how: pkgs/secret-put.sh
      # and skills/step-by-step/SKILL.md §4.
      nixosModules.secret-put = { pkgs, ... }: {
        environment.systemPackages = [ self.packages.${pkgs.system}.secret-put ];
      };
      packages = forAll (pkgs: {
        secret-put = pkgs.writeShellApplication {
          name = "secret-put";
          runtimeInputs = with pkgs; [ coreutils gnugrep gawk gnused ];
          text = builtins.readFile ./pkgs/secret-put.sh;
        };
      });

      # Shared skills. A consumer merges them with its own skills directory:
      #   agent-modules.lib.mkSkills pkgs ./skills
      # Local files are copied over the shared ones, so a host adds its site
      # layer as ./skills/step-by-step/SITE.md and it lands beside the shared
      # SKILL.md. One copy of the method; each site keeps its own facts.
      lib.mkSkills = pkgs: local: pkgs.runCommand "claude-skills" { } ''
        mkdir -p $out
        cp -r ${./skills}/. $out/
        chmod -R u+w $out
        cp -r ${local}/. $out/
      '';

      # `nix flake check` RUNS the adversarial matrix against a fully-rendered
      # guard. This is the point of the whole repo: the guard is a security
      # backstop, and a fence that has stopped firing looks exactly like a fence
      # that was never needed. Making it a flake check means a broken guard
      # cannot be deployed by either consumer.
      checks = forAll (pkgs:
        let
          eval = nixpkgs.lib.nixosSystem {
            system = pkgs.system;
            modules = [
              self.nixosModules.agent
              ({ ... }: {
                boot.loader.grub.enable = false;
                fileSystems."/" = { device = "none"; fsType = "tmpfs"; };
                system.stateVersion = "26.05";
                users.users.claude = { isNormalUser = true; home = "/home/claude"; };
                services.claudeAgent = {
                  enable = true;
                  user = "claude";
                  operator = "Chris";
                  deniedApplyCommands = [ "nixos-rebuild" ];
                };
              })
            ];
          };
          guard = eval.config.environment.etc."claude-code/pretooluse-guard.sh".source;
        in
        {
          guard-matrix = pkgs.runCommand "guard-matrix"
            { nativeBuildInputs = [ pkgs.jq pkgs.gawk pkgs.bash pkgs.gnugrep pkgs.gnused pkgs.coreutils ]; }
            ''
              # The guard pins its own PATH (so a missing jq cannot silently
              # disable a security backstop), which means a fake `id` on PATH is
              # correctly ignored. So rather than fake the identity, rewrite the
              # ONE generated line to the build user and test the logic directly.
              # The scope guard gets its own assertion below — testing it by
              # subverting it would prove nothing.
              ME=$(id -un)
              sed "s|^AGENT_USER=.*|AGENT_USER='$ME'|" ${guard} > guard-under-test.sh
              chmod +x guard-under-test.sh
              grep -q "^AGENT_USER='$ME'" guard-under-test.sh || { echo "could not retarget AGENT_USER"; exit 1; }

              echo "=== adversarial matrix, as the agent ==="
              bash ${./tests/guard-test.sh} ./guard-under-test.sh ${./tests/guard-cases.tsv} /home/claude | tee out.txt
              grep -q 'fail=0' out.txt || { echo "GUARD MATRIX FAILED"; exit 1; }

              echo
              echo "=== scope guard: the UNMODIFIED guard must fall through for a non-agent ==="
              # AGENT_USER is 'claude'; the build user is not, so this must be {}.
              got=$(jq -n '{tool_name:"Bash",cwd:"/home/chris",tool_input:{command:"rm -rf /etc/passwd"}}' | bash ${guard})
              [ "$got" = "{}" ] || { echo "FAIL: guard did not fall through for a non-agent user (got: $got)"; exit 1; }
              echo "  ok: falls through for a non-agent user"

              # ...and the SAME payload must still be denied for the agent.
              got2=$(jq -n '{tool_name:"Bash",cwd:"/home/claude",tool_input:{command:"rm -rf /etc/hosts"}}' \
                     | bash ./guard-under-test.sh | jq -r '.hookSpecificOutput.permissionDecision // "none"')
              [ "$got2" = "deny" ] || { echo "FAIL: guard did not deny for the agent (got: $got2)"; exit 1; }
              echo "  ok: still denies for the agent"

              cp out.txt $out
            '';

          # secret-put must behave exactly as SKILL.md §4 promises Chris.
          secret-put = pkgs.runCommand "secret-put-matrix"
            { nativeBuildInputs = [ pkgs.bash pkgs.util-linux pkgs.coreutils pkgs.findutils pkgs.gnugrep ]; }
            ''
              bash ${./tests/secret-put-test.sh} ${self.packages.${pkgs.system}.secret-put}/bin/secret-put $TMPDIR/sp | tee out.txt
              grep -q 'fail=0' out.txt || { echo "SECRET-PUT MATRIX FAILED"; exit 1; }
              cp out.txt $out
            '';

          # Every shared skill has frontmatter with a name and a description.
          skills = pkgs.runCommand "skills-frontmatter" { } ''
            for f in ${./skills}/*/SKILL.md; do
              head -1 "$f" | grep -qx -- '---' || { echo "no frontmatter: $f"; exit 1; }
              grep -q '^name: ' "$f" && grep -q '^description: ' "$f" || { echo "missing name/description: $f"; exit 1; }
            done
            touch $out
          '';
        });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell { packages = with pkgs; [ jq gawk shellcheck ]; };
      });
    };
}
