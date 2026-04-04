import { useCallback, useMemo, useState } from 'react'
import {
	DefaultSizeStyle,
	Editor,
	ErrorBoundary,
	TLComponents,
	TLShapePartial,
	Tldraw,
	TldrawOverlays,
	TldrawUiToastsProvider,
	TLUiOverrides,
	createShapeId,
	toRichText,
} from 'tldraw'
import { TldrawAgentApp } from './agent/TldrawAgentApp'
import {
	TldrawAgentAppContextProvider,
	TldrawAgentAppProvider,
} from './agent/TldrawAgentAppProvider'
import { ChatPanel } from './components/ChatPanel'
import { ChatPanelFallback } from './components/ChatPanelFallback'
import { CustomHelperButtons } from './components/CustomHelperButtons'
import { AgentViewportBoundsHighlights } from './components/highlights/AgentViewportBoundsHighlights'
import { AllContextHighlights } from './components/highlights/ContextHighlights'
import { TargetAreaTool } from './tools/TargetAreaTool'
import { TargetShapeTool } from './tools/TargetShapeTool'

// Customize tldraw's styles to play to the agent's strengths
DefaultSizeStyle.setDefaultValue('s')

// Custom tools for picking context items
const tools = [TargetShapeTool, TargetAreaTool]
const overrides: TLUiOverrides = {
	tools: (editor, tools) => {
		return {
			...tools,
			'target-area': {
				id: 'target-area',
				label: 'Pick Area',
				kbd: 'c',
				icon: 'tool-frame',
				onSelect() {
					editor.setCurrentTool('target-area')
				},
			},
			'target-shape': {
				id: 'target-shape',
				label: 'Pick Shape',
				kbd: 's',
				icon: 'tool-frame',
				onSelect() {
					editor.setCurrentTool('target-shape')
				},
			},
		}
	},
}

function geo(
	id: string,
	x: number,
	y: number,
	w: number,
	h: number,
	text: string,
	color: 'blue' | 'light-blue' | 'orange' | 'green' | 'yellow' | 'violet' | 'light-violet' | 'grey',
	font: 'sans' | 'mono' = 'sans',
	fill: 'solid' | 'semi' = 'semi'
): TLShapePartial<'geo'> {
	return {
		id: createShapeId(id),
		type: 'geo',
		x,
		y,
		props: {
			w,
			h,
			geo: 'rectangle',
			color,
			fill,
			font,
			align: 'middle',
			verticalAlign: 'middle',
			richText: toRichText(text),
		},
	}
}

function text(id: string, x: number, y: number, w: number, value: string): TLShapePartial<'text'> {
	return {
		id: createShapeId(id),
		type: 'text',
		x,
		y,
		props: {
			w,
			autoSize: false,
			color: 'black',
			font: 'sans',
			textAlign: 'middle',
			richText: toRichText(value),
		},
	}
}

function arrow(
	id: string,
	x1: number,
	y1: number,
	x2: number,
	y2: number,
	label = '',
	bend = 0
): TLShapePartial<'arrow'> {
	return {
		id: createShapeId(id),
		type: 'arrow',
		x: x1,
		y: y1,
		props: {
			start: { x: 0, y: 0 },
			end: { x: x2 - x1, y: y2 - y1 },
			bend,
			color: 'black',
			dash: 'draw',
			richText: toRichText(label),
		},
	}
}

const VARINT_SHAPE_IDS = [
	'rv-title',
	'rv-version',
	'rv-code',
	'rv-legend',
	'rv-input',
	'rv-input-note',
	'rv-step1',
	'rv-state1',
	'rv-step2',
	'rv-byte1',
	'rv-flow1',
	'rv-step3',
	'rv-advance1',
	'rv-step4',
	'rv-byte2',
	'rv-flow2',
	'rv-step5',
	'rv-advance2',
	'rv-step6',
	'rv-return',
	'rv-ninth',
	'rv-a1',
	'rv-a2',
	'rv-a3',
	'rv-a4',
	'rv-a5',
	'rv-a6',
].map((id) => createShapeId(id))

function seedVarintDiagram(editor: Editor) {
	const versionShape = editor.getShape(createShapeId('rv-version'))
	if (versionShape) return

	const allShapes = editor.getCurrentPageShapes()
	if (allShapes.length > 0) {
		editor.deleteShapes(allShapes.map((shape) => shape.id))
	}

	const shapes: TLShapePartial[] = [
		text('rv-title', 980, 20, 900, 'read_varint_at line by line'),
		text('rv-version', 1700, 20, 220, 'diagram v5'),
		geo(
			'rv-code',
			40,
			110,
			760,
			940,
			'1  pub fn read_varint_at(buffer: &[u8], mut offset: usize) -> (u8, i64) {\n2      let mut size = 0;\n3      let mut result = 0;\n4\n5      while size < 9 {\n6          let current_byte = buffer[offset] as i64;\n7          if size == 8 {\n8              result = (result << 8) | current_byte;\n9          } else {\n10             result = (result << 7) | (current_byte & 0b0111_1111);\n11         }\n12\n13         offset += 1;\n14         size += 1;\n15\n16         if current_byte & 0b1000_0000 == 0 {\n17             break;\n18         }\n19     }\n20\n21     (size, result)\n22 }\n',
			'grey',
			'mono'
		),
		geo(
			'rv-legend',
			40,
			1090,
			760,
			180,
			'Reading guide\nsize = how many bytes of the varint have been consumed\nresult = decoded integer built so far\noffset = where the next byte is read from\nExample input bytes for the walkthrough: [0x81, 0x2C]',
			'light-violet',
			'mono'
		),
		geo(
			'rv-input',
			900,
			110,
			1040,
			130,
			'Input bytes used for the walkthrough\nbyte 0 = 0x81 = 1000_0001\nbyte 1 = 0x2C = 0010_1100',
			'light-blue',
			'mono'
		),
		text(
			'rv-input-note',
			1420,
			255,
			560,
			'Top bit 1 means continue. Top bit 0 means stop. Lower 7 bits are payload except on the 9th byte.'
		),
		geo(
			'rv-step1',
			900,
			310,
			460,
			180,
			'Step 1\nLines 2-3\nInitialize state\nsize = 0\nresult = 0\noffset = 0',
			'orange',
			'mono'
		),
		geo(
			'rv-state1',
			1470,
			310,
			470,
			180,
			'State after initialization\nNo bits have been gathered yet.\nresult bits = 00000000\nsize says 0 bytes consumed.',
			'light-blue',
			'mono'
		),
		arrow('rv-a1', 1360, 400, 1470, 400, 'state snapshot', -18),
		geo(
			'rv-step2',
			900,
			560,
			460,
			260,
			'Step 2\nLines 5-10 on first loop iteration\nRead current_byte = 1000_0001\nsize is not 8, so use line 10\npayload bits = current_byte & 0111_1111 = 0000001\nresult before = 0000000\nresult << 7 = 0000000\nnew result = 0000000 | 0000001 = 0000001',
			'green',
			'mono'
		),
		geo(
			'rv-byte1',
			1470,
			560,
			470,
			110,
			'Bit flow for byte 1\n1000_0001\n& 0111_1111\n= 0000_0001',
			'yellow',
			'mono'
		),
		geo(
			'rv-flow1',
			1470,
			700,
			470,
			120,
			'Result gathering after byte 1\n0000000 << 7 = 0000000\n0000000 | 0000001 = 0000001\nresult = 1',
			'light-violet',
			'mono'
		),
		arrow('rv-a2', 1360, 690, 1470, 690, 'bits become result', -18),
		geo(
			'rv-step3',
			900,
			880,
			460,
			220,
			'Step 3\nLines 13-17 after first byte\noffset += 1 -> 1\nsize += 1 -> 1\ncurrent_byte & 1000_0000 != 0\nHigh bit is 1, so do not break.\nLoop continues to the next byte.',
			'orange',
			'mono'
		),
		geo(
			'rv-advance1',
			1470,
			880,
			470,
			220,
			'State before second iteration\noffset = 1\nsize = 1\nresult = 1\nThe next byte read will be buffer[1] = 0x2C',
			'light-blue',
			'mono'
		),
		arrow('rv-a3', 1360, 990, 1470, 990, 'continue loop', -18),
		geo(
			'rv-step4',
			900,
			1160,
			460,
			280,
			'Step 4\nLines 5-10 on second loop iteration\nRead current_byte = 0010_1100\nsize is still not 8, so use line 10\npayload bits = 00101100 & 01111111 = 0101100\nresult before = 0000001\nresult << 7 = 10000000\nnew result = 10000000 | 00101100 = 10101100',
			'green',
			'mono'
		),
		geo(
			'rv-byte2',
			1470,
			1160,
			470,
			120,
			'Bit flow for byte 2\n0010_1100\n& 0111_1111\n= 0010_1100',
			'yellow',
			'mono'
		),
		geo(
			'rv-flow2',
			1470,
			1310,
			470,
			130,
			'Result gathering after byte 2\n0000001 << 7 = 10000000\n10000000 | 00101100 = 10101100\nresult = 172',
			'light-violet',
			'mono'
		),
		arrow('rv-a4', 1360, 1290, 1470, 1290, 'bits become result', -18),
		geo(
			'rv-step5',
			900,
			1490,
			460,
			220,
			'Step 5\nLines 13-17 after second byte\noffset += 1 -> 2\nsize += 1 -> 2\ncurrent_byte & 1000_0000 == 0\nHigh bit is 0, so break now.',
			'orange',
			'mono'
		),
		geo(
			'rv-advance2',
			1470,
			1490,
			470,
			220,
			'Loop exit state\noffset = 2\nsize = 2\nresult = 172\nTwo bytes were consumed to encode this varint.',
			'light-blue',
			'mono'
		),
		arrow('rv-a5', 1360, 1600, 1470, 1600, 'break and stop', -18),
		geo(
			'rv-step6',
			900,
			1760,
			460,
			140,
			'Step 6\nLine 21\nReturn (size, result)',
			'green',
			'mono'
		),
		geo(
			'rv-return',
			1470,
			1760,
			470,
			140,
			'Final output for [0x81, 0x2C]\n(size, result) = (2, 172)\n2 = bytes consumed\n172 = decoded integer value',
			'light-violet',
			'mono'
		),
		arrow('rv-a6', 1360, 1830, 1470, 1830, 'returned tuple', -18),
		geo(
			'rv-ninth',
			40,
			1320,
			760,
			180,
			'Special case\nLines 7-8 only run on the 9th byte of a SQLite varint.\nBytes 1 through 8 contribute 7 bits each.\nThe 9th byte contributes all 8 bits, so the code shifts by 8 instead of 7.',
			'violet',
			'mono'
		),
	]

	editor.run(() => {
		editor.createShapes(shapes)
		editor.zoomToFit({ immediate: true })
	})
}

function App() {
	const [app, setApp] = useState<TldrawAgentApp | null>(null)

	const handleUnmount = useCallback(() => {
		setApp(null)
	}, [])

	// Custom components to visualize what the agent is doing
	// These use TldrawAgentAppContextProvider to access the app/agent
	const components: TLComponents = useMemo(() => {
		return {
			HelperButtons: () =>
				app && (
					<TldrawAgentAppContextProvider app={app}>
						<CustomHelperButtons />
					</TldrawAgentAppContextProvider>
				),
			Overlays: () => (
				<>
					<TldrawOverlays />
					{app && (
						<TldrawAgentAppContextProvider app={app}>
							<AgentViewportBoundsHighlights />
							<AllContextHighlights />
						</TldrawAgentAppContextProvider>
					)}
				</>
			),
		}
	}, [app])

	return (
		<TldrawUiToastsProvider>
			<div className="tldraw-agent-container">
				<div className="tldraw-canvas">
					<Tldraw
						persistenceKey="tldraw-agent-demo"
						tools={tools}
						overrides={overrides}
						components={components}
						onMount={seedVarintDiagram}
					>
						<TldrawAgentAppProvider onMount={setApp} onUnmount={handleUnmount} />
					</Tldraw>
				</div>
				<ErrorBoundary fallback={ChatPanelFallback}>
					{app && (
						<TldrawAgentAppContextProvider app={app}>
							<ChatPanel />
						</TldrawAgentAppContextProvider>
					)}
				</ErrorBoundary>
			</div>
		</TldrawUiToastsProvider>
	)
}

export default App
