import argparse
import os

DEBUG = True


def main():
    parser = argparse.ArgumentParser(
        description="Parse arguments for password, tmux session, and commands."
    )

    # Define required arguments
    parser.add_argument("--pwd", required=False, help="Password input")
    parser.add_argument("--tmux", required=False, help="Tmux session name")

    # Capture all remaining arguments
    parser.add_argument(
        "commands", nargs=argparse.REMAINDER, help="Remaining command-line arguments"
    )

    # Parse arguments
    args = parser.parse_args()

    if args.pwd:
        os.chdir(args.pwd)

    # Output the parsed results
    if DEBUG:
        print(f"Password: {args.pwd}")
        print(f"Tmux Session: {args.tmux}")
        print(f"Remaining Commands: {args.commands}")

    # using double quotes
    formatted_commands = " ".join([f'"{c}"' if " " in c else c for c in args.commands])

    if DEBUG:
        print(f"Packed command: {formatted_commands}")

    if args.tmux:
        formatted_commands = (
            f"tmux new-session -s {args.tmux} '{formatted_commands} ; bash'"
        )

    os.execvp("bash", ["bash", "--login", "-i", "-c", formatted_commands])


if __name__ == "__main__":
    main()
