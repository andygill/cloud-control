import argparse
import json
import struct
import os
import sys


def top_n_values(d, n=5):
    # Sort the dictionary by value in descending order
    sorted_items = sorted(d.items(), key=lambda item: item[1], reverse=True)
    if n is not None:
        # Take the top n items
        sorted_items = sorted_items[:n]
    # Convert the list of tuples back to a dictionary
    return dict(sorted_items)


def main():
    parser = argparse.ArgumentParser(description="Process .safetensors files.")
    parser.add_argument("--all", action="store_true", help="Process all tags")
    parser.add_argument("filename", nargs="?", help="Filename to process")
    args = parser.parse_args()

    n = None if args.all else 5

    if args.filename:
        if os.path.isfile(args.filename):
            filenames = [args.filename]
        else:
            print(f"File '{args.filename}' does not exist or is not a file.")
            sys.exit(1)
    else:
        # Get all .safetensors files in the current directory
        filenames = [
            f
            for f in os.listdir(".")
            if os.path.isfile(f) and f.endswith(".safetensors")
        ]

    if not filenames:
        print("No .safetensors files found.")
        sys.exit(0)

    for filename in filenames:
        print(f"# {filename}")

        with open(filename, "rb") as f:
            length_of_header = struct.unpack("<Q", f.read(8))[0]
            header_data = f.read(length_of_header)
            header = json.loads(header_data)
            try:
                ss_output_name = header["__metadata__"]["ss_output_name"]
            except KeyError:
                continue
            print(f"[{ss_output_name}]")
            ss_tag_frequency = json.loads(header["__metadata__"]["ss_tag_frequency"])
            for key in ss_tag_frequency.keys():
                print(f"    [{ss_output_name}.{key}]")
                tags = ss_tag_frequency[key]
                top_tags = top_n_values(tags, n)
                for k in top_tags.keys():
                    print(f"    {k} = {tags[k]}")
            print()


if __name__ == "__main__":
    main()
