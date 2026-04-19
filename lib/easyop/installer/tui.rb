# frozen_string_literal: true

module Easyop
  module Installer
    module Tui
      module_function

      begin
        require "io/console"
        IO_CONSOLE = true
      rescue LoadError
        IO_CONSOLE = false
      end

      def tty?
        IO_CONSOLE && $stdin.isatty && $stdout.isatty
      end

      def colorize(text, *codes)
        return text unless tty?
        "\e[#{codes.join(";")}m#{text}\e[0m"
      end

      def green(s)  = colorize(s, 32)
      def cyan(s)   = colorize(s, 36)
      def yellow(s) = colorize(s, 33)
      def red(s)    = colorize(s, 31)
      def bold(s)   = colorize(s, 1)
      def dim(s)    = colorize(s, 2)
      def underline(s) = colorize(s, 4)

      def banner
        puts
        puts bold(cyan("  ┌──────────────────────────────────────────────────┐"))
        puts bold(cyan("  │") + "       #{bold("EasyOp")} Installation Wizard                  " + cyan("│"))
        puts bold(cyan("  │") + "  #{dim("Joyful, composable business logic for Ruby")}    " + cyan("│"))
        puts bold(cyan("  └──────────────────────────────────────────────────┘"))
        puts
      end

      def section(title)
        puts
        puts "  #{bold(underline(title))}"
        puts
      end

      def say(msg = "")
        puts "  #{msg}"
      end

      def success(msg)
        puts "  #{green("✓")} #{msg}"
      end

      def info(msg)
        puts "  #{cyan("ℹ")} #{dim(msg)}"
      end

      def warn_msg(msg)
        puts "  #{yellow("!")} #{msg}"
      end

      def status(verb, path)
        color = case verb
                when "create" then :green
                when "skip"   then :dim
                when "exist"  then :yellow
                when "error"  then :red
                else               :cyan
                end
        colored = send(color, verb.ljust(8))
        puts "      #{colored}  #{path}"
      end

      def separator
        puts "  #{dim("─" * 52)}"
      end

      def ask(prompt, default: nil)
        hint = default && !default.empty? ? dim(" (#{default})") : ""
        print "  #{cyan("?")} #{prompt}#{hint}: "
        input = $stdin.gets.to_s.strip
        input.empty? ? default.to_s : input
      end

      def yes?(prompt, default: true)
        hint = default ? dim(" [Y/n]") : dim(" [y/N]")
        print "  #{cyan("?")} #{prompt}#{hint}: "
        input = $stdin.gets.to_s.strip.downcase
        return default if input.empty?
        input.start_with?("y")
      end

      # choices: Array of { name:, value:, selected: bool, hint: }
      # Returns Array of selected values.
      def multiselect(prompt, choices)
        selected = choices.select { |c| c[:selected] }.map { |c| c[:value] }

        unless tty?
          return non_tty_multiselect(prompt, choices, selected)
        end

        cursor  = 0
        height  = choices.length

        puts "  #{cyan("?")} #{bold(prompt)}"
        puts dim("    ↑↓ move · space toggle · a select-all · n deselect-all · enter confirm")
        puts

        render = lambda do
          choices.each_with_index do |c, i|
            checked  = selected.include?(c[:value]) ? green("◉") : dim("○")
            arrow    = i == cursor ? cyan("›") : " "
            label    = selected.include?(c[:value]) ? bold(c[:name]) : c[:name]
            hint_str = c[:hint] ? dim("  #{c[:hint]}") : ""
            puts "    #{arrow} #{checked} #{label}#{hint_str}"
          end
        end

        render.call

        $stdin.raw do |io|
          loop do
            print "\e[#{height}A\e[0J"
            render.call

            char = io.getc
            case char
            when "\r", "\n"
              break
            when " "
              val = choices[cursor][:value]
              selected.include?(val) ? selected.delete(val) : selected << val
            when "a"
              selected = choices.map { |c| c[:value] }
            when "n"
              selected = []
            when "\e"
              seq = (io.getc rescue "") + (io.getc rescue "")
              case seq
              when "[A" then cursor = (cursor - 1 + height) % height
              when "[B" then cursor = (cursor + 1) % height
              end
            when "\u0003"
              puts
              exit(1)
            end
          end
        end

        puts
        selected
      end

      def non_tty_multiselect(prompt, choices, selected)
        puts "  #{prompt}:"
        choices.each_with_index do |c, i|
          mark = selected.include?(c[:value]) ? "x" : " "
          hint = c[:hint] ? " (#{c[:hint]})" : ""
          puts "    #{i + 1}. [#{mark}] #{c[:name]}#{hint}"
        end
        print "  Toggle numbers (e.g. 1,3) or enter to keep defaults: "
        input = $stdin.gets.to_s.strip
        unless input.empty?
          input.split(",").map(&:strip).each do |n|
            next unless n.match?(/^\d+$/)
            idx = n.to_i - 1
            next unless (0...choices.length).cover?(idx)
            val = choices[idx][:value]
            selected.include?(val) ? selected.delete(val) : selected << val
          end
        end
        selected
      end
    end
  end
end
