# Reads .gstorage file, which contains a gstorage "directory", and figure out the differences.
# Example of .gstorage is gs://xxx-yyy/dirname/dirname

import os
import subprocess
import argparse


def read_gs_path():
    try:
        with open(".gstorage", "r") as file:
            return file.read().strip()
    except FileNotFoundError:
        print("The file '.gstorage' was not found.")
        return
    except Exception as e:
        print(f"An error occurred while reading '.gstorage': {e}")
        return


def status():
    # Read the gs:// path from .gstorage file

    gs_path = read_gs_path()
    # Run 'gsutil ls -l' command
    try:
        result = subprocess.run(
            ["gsutil", "ls", "-l", gs_path],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        output = result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error running 'gsutil ls -l': {e.stderr.strip()}")
        return
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return

    # Parse the output
    remote = {}
    for line in output.strip().split("\n"):
        line = line.strip()
        if line.startswith("TOTAL:"):
            # Skip the total line
            continue
        parts = line.split()
        size, _date, url = parts[0], parts[1], " ".join(parts[2:])
        assert url.startswith(gs_path + "/")
        url = url[len(gs_path) + 1 :]

        if url.endswith("/"):
            # It's a directory; skip it
            continue
        remote[url] = int(size)

    files = os.listdir(os.getcwd())
    files = [f for f in files if not f.startswith(".")]
    files = [f for f in files if not f.endswith("~")]
    files = [f for f in files if os.path.isfile(f)]

    local = {}
    for f in files:
        local[f] = os.path.getsize(f)

    filenames = sorted(set(list(remote.keys()) + list(local.keys())))

    data = []
    for f in filenames:
        l = local[f] if f in local else None
        r = remote[f] if f in remote else None
        if l is not None and r is not None and l == r:
            data.append(("", "LR", f"{l:,}", f, ""))
        else:
            tmp = []
            col = []
            if l is not None:
                tmp.append(("L-", f"{l:,}"))
                col.append("\033[1;32m")
            if r is not None:
                tmp.append(("-R", f"{r:,}"))
                col.append("\033[1;34m")
            if len(col) == 2:
                col = ["\033[1;31m"]
            for item in tmp:
                data.append((col[0],) + item + (f, "\033[0m"))

    for l in data:
        print(f"{l[0]}{l[2].rjust(18)} {l[1]} {l[3]}{l[4]}")


def push(filenames):
    assert len(filenames) > 0
    gs_path = read_gs_path()
    try:
        result = subprocess.run(["gsutil", "cp"] + filenames + [gs_path + "/"])
        output = result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error running 'gsutil ls -l': {e.stderr.strip()}")
        return
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return


def pull(filenames):
    assert len(filenames) > 0
    gs_path = read_gs_path()
    filenames = [gs_path + "/" + f for f in filenames]
    try:
        result = subprocess.run(["gsutil", "cp"] + filenames + ["."])
        output = result.stdout
    except subprocess.CalledProcessError as e:
        print(f"Error running 'gsutil ls -l': {e.stderr.strip()}")
        return
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Simulate file management with push, pull, and status."
    )

    subparsers = parser.add_subparsers(dest="command", help="Command to run")

    # Subparser for 'status' command
    subparsers.add_parser(
        "status", help="Display the status of files in the current directory"
    )

    # Subparser for 'push' command
    push_parser = subparsers.add_parser(
        "push", help="Push a file to the backup directory"
    )
    push_parser.add_argument(
        "filenames", nargs="+", type=str, help="The filename to push"
    )

    # Subparser for 'pull' command
    pull_parser = subparsers.add_parser(
        "pull", help="Pull a file from the backup directory"
    )
    pull_parser.add_argument(
        "filenames", nargs="+", type=str, help="The filename to pull"
    )

    parser.set_defaults(command="status")

    args = parser.parse_args()

    if args.command == "status":
        status()
    elif args.command == "push":
        push(args.filenames)
    elif args.command == "pull":
        pull(args.filenames)
    else:
        parser.print_help()
