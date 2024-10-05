import json
import struct
import os


def top_n_values(d, n=5):
    # Sort the dictionary by value in descending order and take the top n items
    top_items = sorted(d.items(), key=lambda item: item[1], reverse=True)[:n]
    # Convert the list of tuples back to a dictionary
    return dict(top_items)


dirname = "."

filenames = [f for f in os.listdir(dirname) if os.path.isfile(os.path.join(dirname, f))]

for filename in filenames:
    if not filename.endswith(".safetensors"):
        continue
    print(f"# {filename}")
    with open(os.path.join(dirname, filename), "rb") as f:
        length_of_header = struct.unpack("<Q", f.read(8))[0]
        header_data = f.read(length_of_header)
        header = json.loads(header_data)
        try:
            ss_output_name = header["__metadata__"]["ss_output_name"]
        except:
            continue
        print(f"[{ss_output_name}]")
        ss_tag_frequency = json.loads(header["__metadata__"]["ss_tag_frequency"])
        for key in ss_tag_frequency.keys():
            print(f"    [{ss_output_name}.{key}]")
            tags = ss_tag_frequency[key]
            for k in top_n_values(tags).keys():
                print(f"    {k} = {tags[k]}")
        print()
