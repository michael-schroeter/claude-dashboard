// A small animated-GIF encoder for the README demo, with nothing to install
// (ImageIO reads the PNG frames; the GIF is written by hand).
//
// Usage:   gif <frames.txt> <out.gif>
//          frames.txt: one frame per line, "<file.png> <delay in 1/100 s>"
//
// Keeps the file small: each frame stores only the rectangle that changed,
// pixels that stayed the same are transparent, and every rectangle gets its
// own palette (exact when it has 255 colors or fewer, median cut otherwise).
// A frame without changes only extends the delay of the one before it.

import CoreGraphics
import Foundation
import ImageIO

struct Image {
  let width: Int
  let height: Int
  let rgb: [UInt32]  // 0xRRGGBB
}

func load(_ path: String) -> Image {
  guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else { fatalError("cannot read \(path)") }
  let width = image.width, height = image.height
  // Draw in the image's own color space, so no colors are converted.
  let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
  var bytes = [UInt8](repeating: 0, count: width * height * 4)
  bytes.withUnsafeMutableBytes { buffer in
    let context = CGContext(
      data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
  }
  var rgb = [UInt32](repeating: 0, count: width * height)
  for i in 0..<width * height {
    rgb[i] = UInt32(bytes[i * 4]) << 16 | UInt32(bytes[i * 4 + 1]) << 8 | UInt32(bytes[i * 4 + 2])
  }
  return Image(width: width, height: height, rgb: rgb)
}

// MARK: - Palette

@inline(__always) func channel(_ color: UInt32, _ c: Int) -> Int { Int((color >> UInt32(16 - 8 * c)) & 0xff) }

/// Median cut over the used colors, weighted by how often they occur.
func palette(_ histogram: [UInt32: Int], size: Int) -> [UInt32] {
  if histogram.count <= size { return Array(histogram.keys) }
  struct Box {
    var colors: [(UInt32, Int)]
    var axis = 0
    var range = 0
    var score = 0.0
    init(_ colors: [(UInt32, Int)]) {
      self.colors = colors
      var lo = [255, 255, 255], hi = [0, 0, 0]
      var total = 0
      for (color, count) in colors {
        total += count
        for c in 0..<3 {
          let v = channel(color, c)
          lo[c] = min(lo[c], v)
          hi[c] = max(hi[c], v)
        }
      }
      let ranges = (0..<3).map { hi[$0] - lo[$0] }
      axis = ranges.firstIndex(of: ranges.max()!)!
      range = ranges[axis]
      // Wide boxes split first, but large areas (backgrounds) still get precise colors.
      score = colors.count > 1 ? Double(range) * Double(total).squareRoot() : -1
    }
  }
  var boxes = [Box(histogram.map { ($0.key, $0.value) })]
  while boxes.count < size {
    guard let index = boxes.indices.max(by: { boxes[$0].score < boxes[$1].score }), boxes[index].score > 0
    else { break }
    let box = boxes.remove(at: index)
    let axis = box.axis
    let sorted = box.colors.sorted { channel($0.0, axis) < channel($1.0, axis) }
    let total = sorted.reduce(0) { $0 + $1.1 }
    var running = 0
    var cut = 1
    for (i, entry) in sorted.enumerated() {
      running += entry.1
      if running * 2 >= total {
        cut = i + 1
        break
      }
    }
    cut = min(max(cut, 1), sorted.count - 1)
    boxes.append(Box(Array(sorted[..<cut])))
    boxes.append(Box(Array(sorted[cut...])))
  }
  return boxes.map { box in
    var sum = [0, 0, 0]
    var total = 0
    for (color, count) in box.colors {
      for c in 0..<3 { sum[c] += channel(color, c) * count }
      total += count
    }
    let avg = (0..<3).map { UInt32((sum[$0] + total / 2) / total) }
    return avg[0] << 16 | avg[1] << 8 | avg[2]
  }
}

func nearest(_ color: UInt32, _ colors: [UInt32]) -> Int {
  var best = 0
  var bestDistance = Int.max
  let r = channel(color, 0), g = channel(color, 1), b = channel(color, 2)
  for (i, p) in colors.enumerated() {
    let dr = r - channel(p, 0), dg = g - channel(p, 1), db = b - channel(p, 2)
    let distance = 3 * dr * dr + 4 * dg * dg + 2 * db * db
    if distance < bestDistance {
      bestDistance = distance
      best = i
      if distance == 0 { break }
    }
  }
  return best
}

// MARK: - LZW (as in GIF89a; same steps as the omggif encoder)

var table = [Int32](repeating: -1, count: 4096 * 256)

func lzw(_ indices: [UInt8], minCodeSize: Int) -> [UInt8] {
  let clearCode = 1 << minCodeSize
  let endCode = clearCode + 1
  var codeSize = minCodeSize + 1
  var nextCode = endCode + 1
  var used: [Int] = []
  var out: [UInt8] = []
  var bits: UInt32 = 0
  var count = 0
  func emit(_ code: Int) {
    bits |= UInt32(code) << UInt32(count)
    count += codeSize
    while count >= 8 {
      out.append(UInt8(bits & 0xff))
      bits >>= 8
      count -= 8
    }
  }
  emit(clearCode)
  var prefix = Int(indices[0])
  for i in 1..<indices.count {
    let k = Int(indices[i])
    let key = prefix << 8 | k
    let code = table[key]
    if code >= 0 {
      prefix = Int(code)
      continue
    }
    emit(prefix)
    if nextCode == 4096 {
      emit(clearCode)
      for u in used { table[u] = -1 }
      used.removeAll(keepingCapacity: true)
      nextCode = endCode + 1
      codeSize = minCodeSize + 1
    } else {
      if nextCode >= 1 << codeSize { codeSize += 1 }
      table[key] = Int32(nextCode)
      used.append(key)
      nextCode += 1
    }
    prefix = k
  }
  emit(prefix)
  emit(endCode)
  if count > 0 { out.append(UInt8(bits & 0xff)) }
  for u in used { table[u] = -1 }
  return out
}

// MARK: - Frames

struct Encoded {
  var x = 0, y = 0, width = 0, height = 0
  var colors: [UInt32] = []
  var transparent: Int? = nil
  var indices: [UInt8] = []
  var delay = 0
}

func encode(_ image: Image, previous: Image?, delay: Int) -> Encoded? {
  let w = image.width, h = image.height
  var x0 = 0, y0 = 0, x1 = w - 1, y1 = h - 1
  if let previous {
    x0 = w; y0 = h; x1 = -1; y1 = -1
    for y in 0..<h {
      let row = y * w
      for x in 0..<w where image.rgb[row + x] != previous.rgb[row + x] {
        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
      }
    }
    if x1 < 0 { return nil }
  }
  var frame = Encoded(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1, delay: delay)
  let changed: (Int) -> Bool = { i in previous == nil || image.rgb[i] != previous!.rgb[i] }

  var histogram: [UInt32: Int] = [:]
  for y in y0...y1 {
    for x in x0...x1 where changed(y * w + x) { histogram[image.rgb[y * w + x], default: 0] += 1 }
  }
  frame.colors = palette(histogram, size: previous == nil ? 256 : 255)
  if previous != nil { frame.transparent = frame.colors.count }
  var lookup: [UInt32: UInt8] = [:]
  for color in histogram.keys { lookup[color] = UInt8(nearest(color, frame.colors)) }

  frame.indices.reserveCapacity(frame.width * frame.height)
  let clear = UInt8(frame.transparent ?? 0)
  for y in y0...y1 {
    for x in x0...x1 {
      let i = y * w + x
      frame.indices.append(changed(i) ? lookup[image.rgb[i]]! : clear)
    }
  }
  return frame
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }

func write(_ frames: [Encoded], width: Int, height: Int, to path: String) -> Int {
  var data: [UInt8] = Array("GIF89a".utf8)
  data += le16(width) + le16(height) + [0x00, 0x00, 0x00]  // no global color table
  data += [0x21, 0xFF, 0x0B] + Array("NETSCAPE2.0".utf8) + [0x03, 0x01, 0x00, 0x00, 0x00]  // loop forever
  for frame in frames {
    let entries = frame.colors.count + (frame.transparent == nil ? 0 : 1)
    var bits = 1
    while 1 << bits < entries { bits += 1 }
    // Graphic control: keep the previous frame (disposal 1), optional transparency.
    let flags: UInt8 = 1 << 2 | (frame.transparent == nil ? 0 : 1)
    data += [0x21, 0xF9, 0x04, flags] + le16(frame.delay) + [UInt8(frame.transparent ?? 0), 0x00]
    data += [0x2C] + le16(frame.x) + le16(frame.y) + le16(frame.width) + le16(frame.height)
    data += [0x80 | UInt8(bits - 1)]
    for i in 0..<(1 << bits) {
      let color = i < frame.colors.count ? frame.colors[i] : 0
      data += [UInt8(color >> 16 & 0xff), UInt8(color >> 8 & 0xff), UInt8(color & 0xff)]
    }
    let minCodeSize = max(2, bits)
    data.append(UInt8(minCodeSize))
    let compressed = lzw(frame.indices, minCodeSize: minCodeSize)
    var offset = 0
    while offset < compressed.count {
      let n = min(255, compressed.count - offset)
      data.append(UInt8(n))
      data += compressed[offset..<offset + n]
      offset += n
    }
    data.append(0x00)
  }
  data.append(0x3B)
  FileManager.default.createFile(atPath: path, contents: Data(data))
  return data.count
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count == 3, let list = try? String(contentsOfFile: args[1], encoding: .utf8) else {
  FileHandle.standardError.write("usage: gif <frames.txt> <out.gif>\n".data(using: .utf8)!)
  exit(1)
}
var frames: [Encoded] = []
var previous: Image? = nil
var total = 0
for line in list.split(separator: "\n") {
  let parts = line.split(separator: " ")
  guard parts.count == 2, let delay = Int(parts[1]) else { continue }
  let image = load(String(parts[0]))
  total += delay
  if let frame = encode(image, previous: previous, delay: delay) {
    frames.append(frame)
  } else {
    frames[frames.count - 1].delay += delay
  }
  previous = image
}
guard let first = previous else { exit(1) }
let bytes = write(frames, width: first.width, height: first.height, to: args[2])
print(String(format: "%@: %d frames, %.2f s, %.2f MB", args[2], frames.count, Double(total) / 100, Double(bytes) / 1_000_000))
