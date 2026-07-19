"""lslib — modular light-show production system.

Pipeline:  song.mp3 -> (atlas GPU analysis) analysis.json
           -> compiler -> show.json (sequence file)
           -> player  -> Art-Net -> atlas bridge -> Hue + fog/laser/strobe
"""
__version__ = "1.0.0"
