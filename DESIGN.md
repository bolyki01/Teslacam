---
version: alpha
name: Teslacam
description: Dark review and export workspace with clean telemetry cards, electric-blue emphasis, and monospaced detail over charcoal panels.
colors:
  background: "#121214"
  background-alt: "#1A1C21"
  surface: "#1C1F26"
  surface-alt: "#262A33"
  primary: "#3D82F8"
  secondary: "#F06047"
  tertiary: "#A7B3C7"
  text: "#F5F7FB"
  text-muted: "#A7B3C7"
  success: "#45C88A"
  warning: "#D6A24A"
  danger: "#F06047"
typography:
  display-lg:
    fontFamily: "SF Pro Display, system-ui, sans-serif"
    fontSize: "30px"
    fontWeight: 700
    lineHeight: "36px"
    letterSpacing: "-0.02em"
  headline-md:
    fontFamily: "SF Pro Display, system-ui, sans-serif"
    fontSize: "24px"
    fontWeight: 700
    lineHeight: "30px"
    letterSpacing: "-0.01em"
  body-md:
    fontFamily: "SF Pro Text, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: "20px"
    letterSpacing: "0em"
  label-sm:
    fontFamily: "SF Pro Text, system-ui, sans-serif"
    fontSize: "10px"
    fontWeight: 600
    lineHeight: "14px"
    letterSpacing: "0.05em"
  mono-sm:
    fontFamily: "SF Mono, ui-monospace, monospace"
    fontSize: "11px"
    fontWeight: 500
    lineHeight: "16px"
    letterSpacing: "0em"
rounded:
  sm: "8px"
  md: "10px"
  lg: "16px"
  xl: "20px"
  full: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "20px"
  xxl: "32px"
components:
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.text}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: "{spacing.lg}"
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "#08131F"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
    height: "44px"
  button-secondary:
    backgroundColor: "{colors.surface-alt}"
    textColor: "{colors.text}"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
    height: "44px"
  telemetry-block:
    backgroundColor: "{colors.surface-alt}"
    textColor: "{colors.text-muted}"
    typography: "{typography.mono-sm}"
    rounded: "{rounded.md}"
    padding: "{spacing.md}"
---

## Overview
TeslaCam should feel like a serious review tool for captured driving footage and export detail. It is dark, clean, and technical, with calm panel structure and sharp telemetry emphasis.

## Colors
The base is charcoal and slate. Electric blue marks primary actions and highlighted timelines. Warm coral is reserved for gaps, faults, or stronger export warnings.

## Typography
Use bold San Francisco titles for navigation and major summaries. Metadata, timestamps, and path-like detail should use monospaced text for clarity.

## Layout
The layout is panel-driven with clear separation between preview, timeline, clip groups, and export detail. Important actions should sit close to the footage or artifact they change.

## Elevation & Depth
Depth should stay subtle and editorial. Cards can separate by tone and edge definition, but the tool should not feel glossy or playful.

## Shapes
Use medium-rounded cards and smaller rounded technical blocks. Pills are optional and should stay secondary to the core panel grid.

## Components
Main elements are preview cards, clip tiles, telemetry blocks, export actions, and technical side panels with compact monospaced metadata.

## Do's and Don'ts
- Do keep clip review and export state immediately visible.
- Do use monospaced typography for technical detail.
- Don't blur the interface into soft generic cards.
- Don't overuse warm warning tones outside actual gaps or faults.
