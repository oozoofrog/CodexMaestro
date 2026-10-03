import AppKit
let destination = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(red: 0.04, green: 0.065, blue: 0.09, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210).fill()
let nodes = [NSPoint(x: 300, y: 320), NSPoint(x: 512, y: 710), NSPoint(x: 735, y: 400)]
NSColor(red: 0.35, green: 0.71, blue: 0.61, alpha: 0.65).setStroke()
let path = NSBezierPath();path.move(to:nodes[0]);path.line(to:nodes[1]);path.line(to:nodes[2]);path.line(to:nodes[0]);path.lineWidth=19;path.lineCapStyle = .round;path.stroke()
for (index, point) in nodes.enumerated() {
 NSColor(red: 0.08, green: 0.14, blue: 0.17, alpha: 1).setFill()
 let outer = NSBezierPath(ovalIn:NSRect(x:point.x-72,y:point.y-72,width:144,height:144));outer.fill()
 NSColor(red:0.49,green:0.9,blue:0.72,alpha:1).setStroke();outer.lineWidth=12;outer.stroke()
 NSColor(red:0.49,green:0.9,blue:0.72,alpha:1).setFill()
 NSBezierPath(ovalIn:NSRect(x:point.x-22,y:point.y-22,width:44,height:44)).fill()
 if index == 1 { NSColor.white.withAlphaComponent(0.85).setFill();NSBezierPath(ovalIn:NSRect(x:point.x-12,y:point.y-12,width:24,height:24)).fill() }
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination))
