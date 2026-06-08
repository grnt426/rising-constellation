<template>
  <default-layout>
    <div class="fluid-panel">
      <v-scrollbar class="panel-aside">
        <div class="panel-aside-bloc">
          <div
            v-if="mode === 'new'"
            class="default-input">
            <label for="name">
              {{ $t('page.create.common.step') }} {{ step.number }}
              <strong>{{ stepLabel }}</strong>
            </label>
            <div class="input-slider">
              <vue-slider
                :lazy="true"
                :min="0" :max="5"
                :interval="1"
                :marks="true"
                :disabled="true"
                :dotSize="16" :height="8"
                :hideLabel="true" tooltip="none"
                v-model="stepCursor">
              </vue-slider>
            </div>
          </div>

          <button
            v-if="stepCursor < 5"
            class="default-button fullsized"
            @click="nextStep">
            {{ $t('page.create.map_editor.next_step_long') }}
            <svgicon name="caret-right" />
          </button>
          <template v-else>
            <button
              v-if="mode === 'new'"
              class="default-button fullsized"
              :disabled="!isValid"
              @click="create">
              <template v-if="waiting">...</template>
              <template v-else>{{ $t('page.create.map_editor.save') }}</template>
            </button>
            <template v-else>
              <button
                class="default-button fullsized"
                :disabled="!isValid"
                @click="update">
                <template v-if="waiting">...</template>
                <template v-else>{{ $t('page.create.map_editor.save_changes') }}</template>
              </button>
              <button
                v-if="!steps[5].map.published_at"
                class="default-button fullsized"
                :disabled="waiting"
                @click="publish">
                <template v-if="waiting">...</template>
                <template v-else>{{ $t('page.create.common.publish') }}</template>
              </button>
              <hr class="separator">
              <button
                class="default-button fullsized"
                @click="destroy">
                <template v-if="waiting">...</template>
                <template v-else>{{ $t('page.create.map_editor.delete') }}</template>
              </button>
            </template>
          </template>
        </div>

        <div
          v-if="mode === 'new'"
          class="panel-aside-info">
          <h2>{{ $t('page.create.common.step') }} {{ step.number }} — {{ stepLabel }}</h2>
          <p class="is-large">
            {{ $t(`page.create.map_editor.step_descriptions.${stepCursor}`) }}
          </p>
        </div>

        <div
          v-if="mode === 'edit' && steps[5].map.author"
          class="panel-aside-info">
          <p>
            {{ $t('page.create.common.by') }} <strong>{{ steps[5].map.author.name }}</strong>
          </p>
          <p v-if="steps[5].map.published_at">
            {{ $t('page.create.common.published_on', { date: formatDate(steps[5].map.published_at) }) }}
          </p>
          <p v-else>
            <strong>{{ $t('page.create.common.draft') }}</strong>
          </p>
          <div class="reactions editor-reactions">
            <button
              class="reaction-button"
              v-tooltip="$t('page.create.common.like')"
              @click="react('likes')">
              <svgicon name="check" />
              <span>{{ steps[5].map.likes || 0 }}</span>
            </button>
            <button
              class="reaction-button"
              v-tooltip="$t('page.create.common.dislike')"
              @click="react('dislikes')">
              <svgicon name="close" />
              <span>{{ steps[5].map.dislikes || 0 }}</span>
            </button>
            <button
              class="reaction-button"
              v-tooltip="$t('page.create.common.favorite')"
              @click="react('favorites')">
              <svgicon name="bookmark" />
              <span>{{ steps[5].map.favorites || 0 }}</span>
            </button>
          </div>
        </div>

        <hr class="separator">

        <div class="panel-aside-bloc">
          <div class="default-input">
            <label for="name">{{ $t('page.create.common.name') }}</label>
            <input
              id="name"
              type="text"
              autocomplete="off"
              placeholder="___"
              v-model="steps[5].map.game_metadata.name" />
          </div>

          <div class="default-input">
            <label for="description">{{ $t('page.create.common.description') }}</label>
            <textarea
              id="description"
              v-model="steps[5].map.game_metadata.description">
            </textarea>
          </div>

        </div>

        <hr class="margin">
      </v-scrollbar>

      <div class="panel-content is-square">
        <router-link
          class="close-button"
          to="/create/maps">
          {{ $t('page.create.common.back') }}
        </router-link>

        <div
          class="content"
          ref="container">
          <svg
            :width="container.width"
            :height="container.width"
            version="1.1"
            xmlns="http://www.w3.org/2000/svg"
            class="map-container">
            <g v-if="displayOptions.grid">
              <line
                v-for="i in Math.round(steps[0].size.value / 12)"
                :key="`v-${i}`"
                x1="0" :y1="resize(i * 12)"
                x2="100%" :y2="resize(i * 12)"
                class="map-grid" />
              <line
                v-for="i in Math.round(steps[0].size.value / 12)"
                :key="`h-${i}`"
                y1="0" :x1="resize(i * 12)"
                y2="100%" :x2="resize(i * 12)"
                class="map-grid" />
            </g>

            <circle
              v-if="displayOptions.circleCursor"
              :cx="mouse.x - container.x"
              :cy="mouse.y - container.y"
              :r="resize(12)"
              class="map-circle-cursor" />
            <circle
              v-if="steps[4].deleteMode"
              :cx="mouse.x - container.x"
              :cy="mouse.y - container.y"
              :r="resize(steps[4].deleteRadius.value)"
              class="map-circle-delete" />
            <circle
              v-if="steps[4].blackholeMode"
              :cx="mouse.x - container.x"
              :cy="mouse.y - container.y"
              :r="resize(steps[4].blackholeRadius.value)"
              class="map-circle-blackhole" />

            <path
              v-if="displayOptions.edges"
              class="map-edges"
              :d="edgesPathStr" />

            <defs>
              <pattern
                id="symmetry-crosshatch"
                patternUnits="userSpaceOnUse"
                width="8" height="8">
                <path
                  d="M-2,2 l4,-4 M0,8 l8,-8 M6,10 l4,-4"
                  stroke="rgba(255, 255, 255, 0.18)"
                  stroke-width="0.7"
                  fill="none" />
              </pattern>
            </defs>

            <g v-if="stepCursor === 2 && ['horizontal', 'vertical', 'both'].includes(steps[2].symmetry.kind)">
              <rect
                v-if="['vertical', 'both'].includes(steps[2].symmetry.kind)"
                :x="resize(symmetryCenter)" :y="0"
                :width="resize(steps[0].size.value) - resize(symmetryCenter)"
                :height="resize(steps[0].size.value)"
                fill="url(#symmetry-crosshatch)"
                style="pointer-events: none" />
              <rect
                v-if="['horizontal', 'both'].includes(steps[2].symmetry.kind)"
                :x="0"
                :y="resize(symmetryCenter)"
                :width="resize(steps[0].size.value)"
                :height="resize(steps[0].size.value) - resize(symmetryCenter)"
                fill="url(#symmetry-crosshatch)"
                style="pointer-events: none" />
              <line
                v-if="['vertical', 'both'].includes(steps[2].symmetry.kind)"
                :x1="resize(symmetryCenter)" :y1="0"
                :x2="resize(symmetryCenter)" :y2="resize(steps[0].size.value)"
                class="map-symmetry-axis" />
              <line
                v-if="['horizontal', 'both'].includes(steps[2].symmetry.kind)"
                :x1="0" :y1="resize(symmetryCenter)"
                :x2="resize(steps[0].size.value)" :y2="resize(symmetryCenter)"
                class="map-symmetry-axis" />
            </g>

            <g v-if="stepCursor === 2 && steps[2].symmetry.kind === 'radial'">
              <polygon
                v-for="(wedge, i) in radialBlockedWedges"
                :key="`hatch-wedge-${i}`"
                :points="wedge.map((p) => `${resize(p[0])},${resize(p[1])}`).join(' ')"
                fill="url(#symmetry-crosshatch)"
                style="pointer-events: none" />
              <line
                v-for="(spoke, i) in radialSpokes"
                :key="`spoke-${i}`"
                :x1="resize(symmetryCenter)" :y1="resize(symmetryCenter)"
                :x2="resize(spoke.end[0])" :y2="resize(spoke.end[1])"
                class="map-symmetry-axis" />
              <circle
                :cx="resize(symmetryCenter)"
                :cy="resize(symmetryCenter)"
                :r="resize(0.7)"
                class="map-symmetry-center"
                style="pointer-events: none" />
            </g>

            <g v-if="stepCursor === 1 || (stepCursor === 2 && steps[2].drawingMode === 'triangles')">
              <polygon
                v-for="t in steps[1].triangles"
                :key="`triangle-${t.key}`"
                :points="t.points.flat().map(p => resize(p)).join()"
                :class="t.color"
                class="map-voronoi-triangle"
                @mouseenter="hoverTriangle(t.key, $event)"
                @click="toggleTriangleToSector(t.key)" />
            </g>

            <g v-if="stepCursor === 2 && steps[2].drawingMode === 'shapes'">
              <polygon
                v-for="p in placedShapes"
                :key="`shape-${p.sectorKey}-${p.shapeIndex}`"
                :points="placedShapePoints(p)"
                :class="[
                  p.color,
                  {
                    'is-selected': isShapeSelected(p),
                    'is-overlap': overlappingSectorKeys.includes(p.sectorKey),
                  },
                ]"
                class="map-sector map-shape-placed"
                :style="{ cursor: steps[2].shapeTool === 'select' ? 'move' : 'default' }"
                @mousedown.stop="onShapeMousedown(p.sectorKey, p.shapeIndex, $event)" />

              <g v-if="selectedShapeObj && steps[2].shapeTool === 'select' && selectedHandlePosition">
                <line
                  :x1="resize(selectedCentroid[0])"
                  :y1="resize(selectedCentroid[1])"
                  :x2="resize(selectedHandlePosition[0])"
                  :y2="resize(selectedHandlePosition[1])"
                  class="map-shape-handle-line"
                  style="pointer-events: none" />
                <circle
                  :cx="resize(selectedHandlePosition[0])"
                  :cy="resize(selectedHandlePosition[1])"
                  :r="resize(1.2)"
                  class="map-shape-handle"
                  @mousedown.stop="onHandleMousedown" />
              </g>

              <polygon
                v-if="rectDraftPolygon"
                :points="shapePolygonAttr(rectDraftPolygon)"
                class="map-shape-preview"
                style="pointer-events: none" />
              <circle
                v-if="steps[2].draft"
                :cx="resize(steps[2].draft.anchor[0])"
                :cy="resize(steps[2].draft.anchor[1])"
                :r="resize(0.5)"
                class="map-shape-anchor"
                style="pointer-events: none" />

              <g v-if="steps[2].polygonDraft">
                <polyline
                  :points="polygonDraftLinePoints"
                  class="map-shape-preview"
                  style="pointer-events: none; fill: none" />
                <line
                  :x1="resize(steps[2].polygonDraft.vertices[steps[2].polygonDraft.vertices.length - 1][0])"
                  :y1="resize(steps[2].polygonDraft.vertices[steps[2].polygonDraft.vertices.length - 1][1])"
                  :x2="resize(polygonSnappedCursor[0])"
                  :y2="resize(polygonSnappedCursor[1])"
                  class="map-shape-preview-trail"
                  style="pointer-events: none" />
                <polyline
                  v-if="polygonClosePreview"
                  :points="polygonClosePreview.points"
                  :class="`is-${polygonClosePreview.kind}`"
                  class="map-shape-close-preview"
                  style="pointer-events: none; fill: none" />
                <circle
                  v-for="(v, i) in steps[2].polygonDraft.vertices"
                  :key="`polydraft-${i}`"
                  :cx="resize(v[0])"
                  :cy="resize(v[1])"
                  :r="resize(0.6)"
                  :class="{ 'is-close-target': i === 0 && polygonDraftCanClose }"
                  class="map-shape-anchor"
                  style="pointer-events: none" />
              </g>

              <circle
                v-if="steps[2].shapeTool === 'polygon'
                  && polygonCursorSnap
                  && !polygonCursorSnap.isDraftStart"
                :cx="resize(polygonCursorSnap.point[0])"
                :cy="resize(polygonCursorSnap.point[1])"
                :r="resize(0.8)"
                class="map-shape-snap-indicator"
                style="pointer-events: none" />
            </g>

            <g v-if="[3, 4, 5].includes(stepCursor)">
              <polygon
                v-for="s in (steps[5].map.game_data ? steps[5].map.game_data.sectors : steps[2].sectors)"
                :key="`map-sector-${s.key}`"
                :points="s.points03.flat().map(p => resize(p)).join()"
                :class="s.color"
                class="map-sector" />

              <circle
                v-for="b in (steps[5].map.game_data ? steps[5].map.game_data.blackholes : steps[4].blackholes)"
                :key="`map-blackhole-${b.key}`"
                :cx="resize(b.position.x)"
                :cy="resize(b.position.y)"
                :r="resize(b.radius)"
                class="map-blackhole" />

              <circle
                v-for="s in (steps[5].map.game_data ? steps[5].map.game_data.systems : steps[3].systems)"
                :key="`map-system-${s.key}`"
                :cx="resize(s.position.x)"
                :cy="resize(s.position.y)"
                :class="s.type"
                class="map-system" />

              <g v-if="displayOptions.sectorInfo">
                <text
                  v-for="s in (steps[5].map.game_data ? steps[5].map.game_data.sectors : steps[2].sectors)"
                  :key="`map-sector-text-${s.key}`"
                  :x="resize(s.centroid[0])"
                  :y="resize(s.centroid[1])"
                  text-anchor="middle"
                  class="map-sector-name">
                  {{ s.name }} ({{ s.systems.length }})
                </text>
              </g>
            </g>
          </svg>

          <hr class="margin">
        </div>
      </div>

      <v-scrollbar class="panel-aside">
        <div class="panel-aside-bloc">
          <div class="checkbox-input has-small-bm">
            <input
              type="checkbox"
              id="grid-option"
              v-model="displayOptions.grid">
            <label
              for="grid-option"
              v-tooltip="$t('page.create.map_editor.show_grid_tooltip')">
              {{ $t('page.create.map_editor.show_grid') }}
            </label>
          </div>

          <div class="checkbox-input has-small-bm">
            <input
              type="checkbox"
              id="circle-cursor-option"
              v-model="displayOptions.circleCursor">
            <label
              for="circle-cursor-option"
              v-tooltip="$t('page.create.map_editor.show_max_bond_distance_tooltip')">
              {{ $t('page.create.map_editor.show_max_bond_distance') }}
            </label>
          </div>

          <div class="checkbox-input has-small-bm">
            <input
              type="checkbox"
              id="circle-sector-option"
              v-model="displayOptions.sectorInfo">
            <label
              for="circle-sector-option"
              v-tooltip="$t('page.create.map_editor.sector_info_tooltip')">
              {{ $t('page.create.map_editor.sector_info') }}
            </label>
          </div>

          <div class="checkbox-input has-small-bm">
            <input
              type="checkbox"
              id="circle-edges-option"
              v-model="displayOptions.edges">
            <label
              for="circle-edges-option"
              v-tooltip="$t('page.create.map_editor.show_connections_tooltip')">
              {{ $t('page.create.map_editor.show_connections') }}
            </label>
          </div>

          <div
            v-if="displayOptions.edges"
            class="checkbox-input"
            style="margin-left: 18px">
            <input
              type="checkbox"
              id="edges-intersector-option"
              v-model="displayOptions.edgesIntersectorOnly">
            <label
              for="edges-intersector-option"
              v-tooltip="$t('page.create.map_editor.edges_intersector_only_tooltip')">
              {{ $t('page.create.map_editor.edges_intersector_only') }}
            </label>
          </div>

          <button
            v-if="stepCursor >= 2"
            class="default-button fullsized has-small-tp"
            @click="exportDebug"
            v-tooltip="$t('page.create.map_editor.debug_export_tooltip')">
            {{ $t('page.create.map_editor.debug_export') }}
          </button>

          <button
            v-if="stepCursor >= 2"
            class="default-button fullsized has-small-tp"
            @click="runEditorTests"
            v-tooltip="$t('page.create.map_editor.tests_run_tooltip')">
            {{ $t('page.create.map_editor.tests_run') }}
          </button>
        </div>

        <hr class="separator">

        <template v-if="stepCursor === 0">
          <div class="panel-aside-bloc">
            <div class="radio-input is-horizontal">
              <div class="label">
                {{ $t('page.create.map_editor.map_size') }}
              </div>
              <div class="content">
                <div
                  v-for="value in steps[0].size.choices"
                  :key="`size-${value}`"
                  class="content-item">
                  <input
                    type="radio"
                    :id="`size-${value}`"
                    :value="value"
                    v-model="steps[0].size.value">
                  <label :for="`size-${value}`">
                    <strong>{{ $t(`map.size.${value}.label`) }}</strong>
                    {{ $t(`map.size.${value}.description`) }}
                  </label>
                </div>
              </div>
            </div>
          </div>

          <div class="panel-aside-info">
            <h2>{{ $t('page.create.common.info') }}</h2>
            <p>{{ $t('page.create.map_editor.info_grid_radius') }}</p>
          </div>
        </template>

        <div
          v-if="stepCursor === 1"
          class="panel-aside-bloc">
          <div class="default-input">
            <label for="seed-step-1">{{ $t('page.create.common.seed') }}</label>
            <input
              id="seed-step-1"
              type="text"
              autocomplete="off"
              v-model="steps[1].seed"
              @input="genVoronoi()" />
            <button
              @click="steps[1].seed = newSeed(); genVoronoi();"
              class="default-button action">
              ↺
            </button>
          </div>

          <div class="default-input">
            <label
              for="grid"
              v-tooltip="$t('page.create.map_editor.triangles_size_tooltip')">
              {{ $t('page.create.map_editor.triangles_size') }}
              <strong>{{ steps[1].grid.value }}</strong>
            </label>
            <div class="input-slider">
              <vue-slider
                :min="steps[1].grid.range.min"
                :max="steps[1].grid.range.max"
                :interval="1"
                :dotSize="16" :height="8"
                :hideLabel="true" tooltip="none"
                @drag-end="genVoronoi()"
                v-model="steps[1].grid.value">
              </vue-slider>
            </div>
          </div>
        </div>

        <template v-if="stepCursor === 2">
          <div class="panel-aside-bloc">
            <div class="radio-input">
              <div class="label">
                {{ $t('page.create.map_editor.drawing_mode') }}
              </div>
              <div class="content">
                <div class="content-item">
                  <input
                    type="radio"
                    id="mode-triangles"
                    value="triangles"
                    v-model="steps[2].drawingMode"
                    @change="onDrawingModeChange">
                  <label for="mode-triangles">{{ $t('page.create.map_editor.mode_triangles') }}</label>
                </div>
                <div class="content-item">
                  <input
                    type="radio"
                    id="mode-shapes"
                    value="shapes"
                    v-model="steps[2].drawingMode"
                    @change="onDrawingModeChange">
                  <label for="mode-shapes">{{ $t('page.create.map_editor.mode_shapes') }}</label>
                </div>
              </div>
            </div>
            <p class="toggle-description">
              {{ $t(`page.create.map_editor.mode_${steps[2].drawingMode}_desc`) }}
            </p>
          </div>

          <div class="panel-aside-bloc">
            <button
              @click="addSector"
              class="default-button">
              {{ $t('page.create.map_editor.add_sector') }}
            </button>
          </div>

          <div class="panel-aside-bloc">
            <template v-if="steps[2].sectors.length > 0">
              <div
                v-for="s in steps[2].sectors.slice().reverse()"
                :key="`s-${s.key}`"
                :class="[
                  { 'active': steps[2].selected === s.key },
                  s.color,
                ]"
                @click="selectSector(s.key)"
                class="selectable-item">
                <div
                  @click.stop="removeSector(s.key)"
                  class="selectable-item-remove">
                  ×
                </div>
                <div class="selectable-item-select"></div>
                <div class="default-input">
                  <input
                    type="text"
                    autocomplete="off"
                    @click.prevent.stop
                    v-model="getSector(s.key).name" />
                </div>
                <div
                  v-if="overlappingSectorKeys.includes(s.key)"
                  v-tooltip="$t('page.create.map_editor.sector_overlap_tooltip')"
                  class="sector-overlap-chip">
                  !
                </div>
              </div>
            </template>
            <div v-else>
              {{ $t('page.create.map_editor.add_at_least_one_sector') }}
            </div>
          </div>

          <div
            v-if="steps[2].drawingMode === 'shapes'"
            class="panel-aside-bloc">
            <div class="radio-input">
              <div class="label">
                {{ $t('page.create.map_editor.shape_tool_heading') }}
              </div>
              <div class="content">
                <div class="content-item">
                  <input
                    type="radio"
                    id="shape-tool-select"
                    value="select"
                    v-model="steps[2].shapeTool"
                    @change="onShapeToolChange">
                  <label for="shape-tool-select">{{ $t('page.create.map_editor.shape_tool_select') }}</label>
                </div>
                <div class="content-item">
                  <input
                    type="radio"
                    id="shape-tool-rect"
                    value="rect"
                    v-model="steps[2].shapeTool"
                    @change="onShapeToolChange">
                  <label for="shape-tool-rect">{{ $t('page.create.map_editor.shape_tool_rectangle') }}</label>
                </div>
                <div class="content-item">
                  <input
                    type="radio"
                    id="shape-tool-polygon"
                    value="polygon"
                    v-model="steps[2].shapeTool"
                    @change="onShapeToolChange">
                  <label for="shape-tool-polygon">{{ $t('page.create.map_editor.shape_tool_polygon') }}</label>
                </div>
              </div>
            </div>

            <div class="checkbox-input has-small-bm">
              <input
                type="checkbox"
                id="snap-enabled"
                v-model="steps[2].snapEnabled">
              <label
                for="snap-enabled"
                v-tooltip="$t('page.create.map_editor.snap_enabled_tooltip')">
                {{ $t('page.create.map_editor.snap_enabled') }}
              </label>
            </div>

            <div
              v-if="steps[2].snapEnabled"
              class="default-input">
              <label for="snap-radius">
                {{ $t('page.create.map_editor.snap_radius') }}
                <strong>{{ steps[2].snapRadius }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="0.5" :max="6"
                  :interval="0.5"
                  :dotSize="16" :height="8"
                  :hideLabel="true" tooltip="none"
                  v-model="steps[2].snapRadius">
                </vue-slider>
              </div>
            </div>
          </div>

          <div class="panel-aside-bloc">
            <div class="radio-input is-grid">
              <div class="label">
                {{ $t('page.create.map_editor.symmetry_heading') }}
              </div>
              <div class="content">
                <div class="content-item">
                  <input
                    type="radio"
                    id="sym-none"
                    value="none"
                    v-model="steps[2].symmetry.kind">
                  <label for="sym-none">{{ $t('page.create.map_editor.symmetry_none') }}</label>
                </div>
                <div class="content-item">
                  <input
                    type="radio"
                    id="sym-h"
                    value="horizontal"
                    v-model="steps[2].symmetry.kind">
                  <label for="sym-h">{{ $t('page.create.map_editor.symmetry_horizontal') }}</label>
                </div>
                <div class="content-item">
                  <input
                    type="radio"
                    id="sym-v"
                    value="vertical"
                    v-model="steps[2].symmetry.kind">
                  <label for="sym-v">{{ $t('page.create.map_editor.symmetry_vertical') }}</label>
                </div>
                <div class="content-item">
                  <input
                    type="radio"
                    id="sym-both"
                    value="both"
                    v-model="steps[2].symmetry.kind">
                  <label for="sym-both">{{ $t('page.create.map_editor.symmetry_both') }}</label>
                </div>
                <div class="content-item">
                  <input
                    type="radio"
                    id="sym-radial"
                    value="radial"
                    v-model="steps[2].symmetry.kind">
                  <label for="sym-radial">{{ $t('page.create.map_editor.symmetry_radial') }}</label>
                </div>
              </div>
            </div>

            <div
              v-if="steps[2].symmetry.kind === 'radial'"
              class="default-input">
              <label for="symmetry-fold">
                {{ $t('page.create.map_editor.symmetry_fold') }}
                <strong>{{ steps[2].symmetry.fold }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="3" :max="8"
                  :interval="1"
                  :marks="[3, 4, 5, 6, 8]"
                  :data="[3, 4, 5, 6, 8]"
                  :dotSize="16" :height="8"
                  :hideLabel="true" tooltip="none"
                  v-model="steps[2].symmetry.fold">
                </vue-slider>
              </div>
            </div>

            <p
              v-if="steps[2].symmetry.kind !== 'none'"
              class="toggle-description">
              {{ $t('page.create.map_editor.symmetry_hint') }}
            </p>
          </div>

          <div
            v-if="steps[2].shapeTool === 'polygon'
              && steps[2].polygonDraft
              && steps[2].polygonDraft.vertices.length >= 3"
            class="panel-aside-bloc">
            <button
              class="default-button fullsized"
              @click="closePolygonDraft">
              {{ $t('page.create.map_editor.polygon_close_button') }}
              <span
                v-if="polygonClosePreview"
                :class="`close-kind close-kind-${polygonClosePreview.kind}`">
                {{ $t(`page.create.map_editor.polygon_close_kind_${polygonClosePreview.kind}`) }}
              </span>
            </button>
            <button
              class="default-button fullsized"
              @click="steps[2].polygonDraft = null">
              {{ $t('page.create.map_editor.polygon_cancel_button') }}
            </button>
          </div>

          <div
            v-if="overlappingSectorKeys.length > 0"
            class="panel-aside-bloc">
            <p class="warning-banner">
              {{ $t('page.create.map_editor.overlap_warning', { count: overlappingSectorKeys.length }) }}
            </p>
          </div>

          <div class="panel-aside-info">
            <h2>{{ $t('page.create.common.info') }}</h2>
            <p v-if="steps[2].drawingMode === 'triangles'">
              {{ $t('page.create.map_editor.info_ctrl_triangles') }}
            </p>
            <p v-else-if="steps[2].shapeTool === 'select'">
              {{ $t('page.create.map_editor.shape_select_hint') }}
            </p>
            <p v-else-if="steps[2].shapeTool === 'polygon' && steps[2].polygonDraft && polygonDraftCanClose">
              {{ $t('page.create.map_editor.polygon_close_now_hint') }}
            </p>
            <p v-else-if="steps[2].shapeTool === 'polygon' && steps[2].polygonDraft && steps[2].polygonDraft.vertices.length >= 3">
              {{ $t('page.create.map_editor.polygon_close_hint') }}
            </p>
            <p v-else-if="steps[2].shapeTool === 'polygon' && steps[2].polygonDraft">
              {{ $t('page.create.map_editor.polygon_continue_hint') }}
            </p>
            <p v-else-if="steps[2].draft">
              {{ $t('page.create.map_editor.shape_draft_hint') }}
            </p>
            <p v-else-if="!steps[2].shapeTool">
              {{ $t('page.create.map_editor.shape_pick_tool') }}
            </p>
            <p v-else-if="!steps[2].selected">
              {{ $t('page.create.map_editor.shape_select_sector_first') }}
            </p>
            <p v-else-if="steps[2].shapeTool === 'polygon'">
              {{ $t('page.create.map_editor.polygon_first_click_hint') }}
            </p>
            <p v-else>
              {{ $t('page.create.map_editor.shape_first_click_hint') }}
            </p>
          </div>
        </template>

        <template v-if="stepCursor === 3">
          <div class="panel-aside-bloc">
            <div class="default-input">
              <label for="seed-step-3">{{ $t('page.create.common.seed') }}</label>
              <input
                id="seed-step-3"
                type="text"
                autocomplete="off"
                v-model="steps[3].seed"
                @input="genSystem()" />
              <button
                @click="steps[3].seed = newSeed(); genSystem();"
                class="default-button action">
                ↺
              </button>
            </div>

            <div class="default-input">
              <label
                for="grid"
                v-tooltip="$t('page.create.map_editor.overall_density_tooltip')">
                {{ $t('page.create.map_editor.overall_density') }}
                <strong>{{ steps[3].density.value }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="steps[3].density.range.min"
                  :max="steps[3].density.range.max"
                  :interval="steps[3].density.interval"
                  :hideLabel="true" tooltip="none"
                  :dotSize="16" :height="8"
                  @drag-end="genSystem()"
                  v-model="steps[3].density.value">
                </vue-slider>
              </div>
            </div>

            <div class="default-input">
              <label
                for="grid"
                v-tooltip="$t('page.create.map_editor.group_density_tooltip')">
                {{ $t('page.create.map_editor.group_density') }}
                <strong>{{ steps[3].maxDensity.value }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="steps[3].maxDensity.range.min"
                  :max="steps[3].maxDensity.range.max"
                  :interval="steps[3].maxDensity.interval"
                  :hideLabel="true" tooltip="none"
                  :dotSize="16" :height="8"
                  @drag-end="genSystem()"
                  v-model="steps[3].maxDensity.value">
                </vue-slider>
              </div>
            </div>

            <div class="default-input">
              <label
                for="grid"
                v-tooltip="$t('page.create.map_editor.group_count_tooltip')">
                {{ $t('page.create.map_editor.group_count') }}
                <strong>{{ steps[3].points.value }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="steps[3].points.range.min"
                  :max="steps[3].points.range.max"
                  :interval="steps[3].points.interval"
                  :hideLabel="true" tooltip="none"
                  :dotSize="16" :height="8"
                  @drag-end="genSystem()"
                  v-model="steps[3].points.value">
                </vue-slider>
              </div>
            </div>

            <div class="default-input">
              <label
                for="grid"
                v-tooltip="$t('page.create.map_editor.group_spread_tooltip')">
                {{ $t('page.create.map_editor.group_spread') }}
                <strong>{{ steps[3].spread.value }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="steps[3].spread.range.min"
                  :max="steps[3].spread.range.max"
                  :interval="steps[3].spread.interval"
                  :hideLabel="true" tooltip="none"
                  :dotSize="16" :height="8"
                  @drag-end="genSystem()"
                  v-model="steps[3].spread.value">
                </vue-slider>
              </div>
            </div>

            <div class="default-input">
              <label
                for="grid"
                v-tooltip="$t('page.create.map_editor.group_attenuation_tooltip')">
                {{ $t('page.create.map_editor.group_attenuation') }}
                <strong>{{ steps[3].attenuation.value }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="steps[3].attenuation.range.min"
                  :max="steps[3].attenuation.range.max"
                  :interval="steps[3].attenuation.interval"
                  :hideLabel="true" tooltip="none"
                  :dotSize="16" :height="8"
                  @drag-end="genSystem()"
                  v-model="steps[3].attenuation.value">
                </vue-slider>
              </div>
            </div>
          </div>

          <div class="panel-aside-bloc">
            <div class="panel-aside-info">
              <h2>{{ $t('page.create.map_editor.per_sector_count_heading') }}</h2>
              <p>{{ $t('page.create.map_editor.per_sector_count_description') }}</p>
            </div>
            <div
              v-for="s in steps[2].sectors"
              :key="`sc-${s.key}`"
              :class="s.color"
              class="sector-count-card">
              <div class="default-input">
                <label
                  :for="`sector-count-${s.key}`"
                  v-tooltip="$t('page.create.map_editor.sector_system_count_tooltip')">
                  {{ s.name }}
                  <strong v-if="s.systems && s.systems.length">{{ s.systems.length }}</strong>
                </label>
                <input
                  :id="`sector-count-${s.key}`"
                  type="number"
                  min="0"
                  :placeholder="$t('page.create.map_editor.sector_system_count_placeholder')"
                  v-model="s.systemCount"
                  @change="onSectorCountChange(s)" />
              </div>
            </div>
          </div>
        </template>

        <template v-if="stepCursor === 4">
          <div class="panel-aside-bloc">
            <div class="checkbox-input has-small-bm">
              <input
                type="checkbox"
                id="delete-mode"
                v-model="steps[4].deleteMode"
                @input="steps[4].blackholeMode = false">
              <label
                for="delete-mode"
                v-tooltip="$t('page.create.map_editor.system_removal_tool_tooltip')">
                {{ $t('page.create.map_editor.system_removal_tool') }}
              </label>
            </div>

            <div class="checkbox-input">
              <input
                type="checkbox"
                id="blackhole-mode"
                v-model="steps[4].blackholeMode"
                @input="steps[4].deleteMode = false">
              <label
                for="blackhole-mode"
                v-tooltip="$t('page.create.map_editor.blackhole_creation_tool_tooltip')">
                {{ $t('page.create.map_editor.blackhole_creation_tool') }}
              </label>
            </div>

            <div
              v-if="steps[4].deleteMode"
              class="default-input">
              <label
                for="grid"
                v-tooltip="$t('page.create.map_editor.deletion_circle_size_tooltip')">
                {{ $t('page.create.map_editor.deletion_circle_size') }}
                <strong>{{ steps[4].deleteRadius.value }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="steps[4].deleteRadius.range.min"
                  :max="steps[4].deleteRadius.range.max"
                  :interval="0.5"
                  :dotSize="16" :height="8"
                  :hideLabel="true" tooltip="none"
                  v-model="steps[4].deleteRadius.value">
                </vue-slider>
              </div>
            </div>

            <div
              v-if="steps[4].blackholeMode"
              class="default-input">
              <label
                for="grid"
                v-tooltip="$t('page.create.map_editor.blackhole_size_tooltip')">
                {{ $t('page.create.map_editor.blackhole_size') }}
                <strong>{{ steps[4].blackholeRadius.value }}</strong>
              </label>
              <div class="input-slider">
                <vue-slider
                  :min="steps[4].blackholeRadius.range.min"
                  :max="steps[4].blackholeRadius.range.max"
                  :interval="0.5"
                  :dotSize="16" :height="8"
                  :hideLabel="true" tooltip="none"
                  v-model="steps[4].blackholeRadius.value">
                </vue-slider>
              </div>
            </div>
          </div>

          <div class="panel-aside-bloc">
            <template v-if="steps[4].blackholes.length > 0">
              <div
                v-for="b in steps[4].blackholes.slice().reverse()"
                :key="`s-${b.key}`"
                class="selectable-item">
                <div
                  @click.stop="removeBlackhole(b.key)"
                  class="selectable-item-remove">
                  ×
                </div>
                <div class="default-input">
                  <input
                    type="text"
                    autocomplete="off"
                    @click.prevent.stop
                    v-model="getBlackhole(b.key).name" />
                </div>
              </div>
            </template>
            <div v-else>
              {{ $t('page.create.map_editor.no_blackholes') }}
            </div>
          </div>
        </template>

        <hr class="margin">
      </v-scrollbar>
    </div>
  </default-layout>
</template>

<script>
import Prando from 'prando';
import VueSlider from 'vue-slider-component';

import DefaultLayout from '@/portal/layouts/Default.vue';
import editor from '@/utils/editor';
import editorTests from '@/utils/editor-tests';

// Shared frozen empty array for the "no edges visible" fast path. A
// fresh literal would create a new reactive observation per call;
// reusing a frozen constant keeps the visibleEdges computed reference-
// equal across re-evaluations and lets the dependent edgesPathStr
// short-circuit cleanly.
const EMPTY_EDGE_LIST = Object.freeze([]);

export default {
  name: 'create-map',
  data() {
    return {
      mode: 'new',
      waiting: false,
      mouse: { x: 0, y: 0 },
      container: { x: 0, y: 0, width: 0 },
      displayOptions: {
        grid: true,
        circleCursor: true,
        // Sector names + system counts are the highest-signal annotation
        // on the map; default to on so authors don't have to discover
        // the toggle.
        sectorInfo: true,
        // Show connections by default — without them the map looks like
        // a starfield with no topology, and most authors want to see
        // what their density / spread / attenuation choices produce.
        // Systems themselves render independently of this toggle; the
        // checkbox only gates the warp-lane preview.
        edges: true,
        // When true, the visible edges are filtered to only those that
        // cross a sector boundary. Useful for very large maps where the
        // intra-sector mesh is too dense to read at a glance.
        edgesIntersectorOnly: false,
      },
      edges: [],
      stepCursor: 0,
      steps: [
        {
          number: 'I',
          size: {
            value: 120,
            choices: [80, 120, 200, 360, 500, 750],
          },
        },
        {
          number: 'II',
          seed: '',
          triangles: [],
          grid: {
            value: 15,
            range: { min: 5, max: 60 },
          },
        },
        {
          number: 'III',
          cursor: 1,
          sectors: [],
          selected: undefined,
          // 'triangles' = legacy Voronoi-grouping flow; 'shapes' = primitive
          // tools (rect / ellipse / N-gon). Sectors can mix freely within
          // a single map — assembleTriangles handles both paths.
          drawingMode: 'triangles',
          // 'select' (move/rotate placed shapes) | 'rect' (two-click corners)
          // | 'polygon' (click vertices, close to commit).
          shapeTool: null,
          // Rectangle two-click state. After the first click, `anchor`
          // holds the first source-coord point; the live preview tracks
          // the cursor; the second click commits the rectangle.
          draft: null,
          // Free-form polygon state. `vertices` is the in-progress vertex
          // list (source coords). `anchors[i]` is the snap target metadata
          // for vertex i (or null if the vertex was placed in open space).
          // Close stitches a shared border via editor.perimeterWalk when
          // the start and last anchors point to the same polygon.
          polygonDraft: null,
          // Selection / transform state for the select tool.
          // selectedShape: {sectorKey, shapeIndex} | null
          // transform: in-flight move/rotate ({kind:'move'|'rotate', ...})
          selectedShape: null,
          transform: null,
          // Vertex/edge snapping. When on, the live preview of a draw
          // or transform is pulled toward any other shape's edge within
          // snapRadius (source units), and the commit uses the snapped
          // polygon. Off-by-default would require users to discover the
          // toggle; default on matches expected CAD behavior.
          snapEnabled: true,
          snapRadius: 2,
          // Symmetry guidance. kind: 'none' | 'horizontal' | 'vertical'
          // | 'both' | 'radial'. For radial, `fold` is the rotation count
          // (3 / 4 / 5 / 6 / 8). Renders axis lines (or spokes for
          // radial) on the canvas, snaps vertices placed within snap
          // radius onto them, cross-hatches the non-canonical region,
          // and auto-mirrors at step 2→3.
          symmetry: { kind: 'none', fold: 4 },
        },
        {
          number: 'IV',
          seed: '',
          systems: [],
          density: {
            value: 50,
            interval: 1,
            range: { min: 0, max: 100 },
          },
          maxDensity: {
            value: 12,
            interval: 1,
            range: { min: 0, max: 100 },
          },
          points: {
            value: 5,
            interval: 1,
            range: { min: 1, max: 20 },
          },
          spread: {
            value: 1,
            interval: 0.05,
            range: { min: 0, max: 5 },
          },
          attenuation: {
            value: 2.5,
            interval: 0.1,
            range: { min: 1, max: 10 },
          },
        },
        {
          number: 'V',
          deleteRadius: {
            value: 2,
            range: { min: 1, max: 5 },
          },
          deleteMode: false,
          blackholeRadius: {
            value: 5,
            range: { min: 1, max: 12 },
          },
          blackholeMode: false,
          cursor: 1,
          blackholes: [],
        },
        {
          number: 'VI',
          map: {
            is_map: true,
            is_official: false,
            game_data: null,
            game_metadata: {
              name: '',
              description: '',
              size: null,
              system_number: 0,
              sector_number: 0,
            },
            thumbnail: undefined,
          },
        },
      ],
    };
  },
  computed: {
    data() { return this.$store.state.portal.data; },
    step() { return this.steps[this.stepCursor]; },
    stepLabel() { return this.$t(`page.create.map_editor.step_labels.${this.stepCursor}`); },
    isValid() { return this.stepCursor === 5 && this.steps[5].map.game_metadata.name !== '' && !this.waiting; },
    // Source-of-truth for the preview-edges call. In edit mode (a map
    // loaded from the API) systems live under steps[5].map.game_data,
    // not in the wizard's steps[3] / steps[4] working buffers — those
    // stay empty until the user enters create mode and walks the
    // wizard. The original code only watched the wizard buffers, so
    // /create/map/:id never rendered the warp lanes.
    edgeSource() {
      const gd = this.steps[5].map.game_data;
      if (gd && gd.systems && gd.systems.length > 0) {
        return { systems: gd.systems, blackholes: gd.blackholes || [] };
      }
      return { systems: this.steps[3].systems, blackholes: this.steps[4].blackholes };
    },
    extractEdges() {
      return this.edgeSource.systems.length + this.edgeSource.blackholes.length;
    },
    // Edges actually visible after the display filters apply. When the
    // user enables "Inter-sector only," we build a (x,y)→sectorKey map
    // once and filter — O(systems + edges), much smaller than the
    // O(edges²) hot path that's already been deflated by the freeze.
    // Cached by Vue; only re-runs when edges, sectors, or the toggle
    // change. The integer-position lookup works because system
    // placements are always integer source units.
    visibleEdges() {
      if (!this.displayOptions.edges) return EMPTY_EDGE_LIST;
      const edges = this.edges;
      if (!this.displayOptions.edgesIntersectorOnly) return edges;

      // Build position-keyed sector lookup. Pull from the same source
      // edgeSource uses so saved-map mode and live-edit mode both work.
      const gd = this.steps[5].map.game_data;
      const sectors = (gd && gd.sectors) || this.steps[2].sectors;
      const posToSector = new Map();
      for (let i = 0; i < sectors.length; i += 1) {
        const sector = sectors[i];
        const list = sector.systems || [];
        for (let j = 0; j < list.length; j += 1) {
          const p = list[j].position;
          if (p) posToSector.set(`${p.x},${p.y}`, sector.key);
        }
      }
      const out = [];
      for (let i = 0; i < edges.length; i += 1) {
        const e = edges[i];
        const a = e.s1.position;
        const b = e.s2.position;
        const sa = posToSector.get(`${a.x},${a.y}`);
        const sb = posToSector.get(`${b.x},${b.y}`);
        if (sa !== undefined && sb !== undefined && sa !== sb) out.push(e);
      }
      return out;
    },
    // Memoized SVG path string for the warp-lane preview. Recomputes
    // only when visibleEdges (i.e. edges, sectors, or display toggles)
    // changes. The inner loop pulls reactive accessors out and builds
    // via Array.join — string `+=` at 10k+ edges hits engine-dependent
    // rope-vs-flat-string thresholds and can degrade to O(N²).
    edgesPathStr() {
      const factor = this.container.width / this.steps[0].size.value;
      const edges = this.visibleEdges;
      const n = edges.length;
      const parts = new Array(n);
      for (let i = 0; i < n; i += 1) {
        const e = edges[i];
        const a = e.s1.position;
        const b = e.s2.position;
        parts[i] = `M ${Math.round(a.x * factor * 100) / 100} ${Math.round(a.y * factor * 100) / 100} L ${Math.round(b.x * factor * 100) / 100} ${Math.round(b.y * factor * 100) / 100}`;
      }
      return parts.join('');
    },
    // Flat list of {sectorKey, shapeIndex, shape, color} for SVG iteration.
    // Built lazily so the template doesn't have to do a nested v-for and
    // can use a stable key per primitive.
    placedShapes() {
      const out = [];
      this.steps[2].sectors.forEach((s) => {
        (s.shapes || []).forEach((shape, idx) => {
          out.push({ sectorKey: s.key, shapeIndex: idx, shape, color: s.color });
        });
      });
      return out;
    },
    // Cursor in source coords. Used as the "drag-to" point for live
    // preview during draw, move, and rotate.
    cursorSource() {
      return [
        this.rresize(this.mouse.x - this.container.x),
        this.rresize(this.mouse.y - this.container.y),
      ];
    },
    // Live rectangle preview between anchor and cursor. Null when not
    // mid-draw with the rect tool.
    rectDraftPolygon() {
      if (this.stepCursor !== 2) return null;
      if (this.steps[2].drawingMode !== 'shapes') return null;
      if (this.steps[2].shapeTool !== 'rect') return null;
      if (!this.steps[2].draft) return null;
      const raw = editor.genRect(this.steps[2].draft.anchor, this.cursorSource);
      return this.applySnap(raw, null) || raw;
    },
    // Coordinate of the symmetry axis (axes share the same center on
    // both X and Y). Map size is the only knob that affects this.
    symmetryCenter() {
      return this.steps[0].size.value / 2;
    },
    // For radial mode: list of spokes as {angle, end} pairs. angle is
    // measured clockwise from "up" so angle 0 points north. end is the
    // spoke endpoint in source coords, extended past the canvas
    // boundary so the line goes off-screen visually.
    radialSpokes() {
      if (this.steps[2].symmetry.kind !== 'radial') return [];
      const fold = this.steps[2].symmetry.fold;
      const c = this.symmetryCenter;
      const length = this.steps[0].size.value;
      const out = [];
      for (let k = 0; k < fold; k += 1) {
        const theta = (k * 2 * Math.PI) / fold;
        out.push({
          angle: theta,
          end: [c + (length * Math.sin(theta)), c - (length * Math.cos(theta))],
        });
      }
      return out;
    },
    // Polygons that cover the non-canonical fold copies for the radial
    // cross-hatch overlay. One wedge per non-canonical fold (k = 1
    // through fold-1). Each wedge is sampled as 10 points along its
    // arc plus the center, so even 120° wedges render smoothly.
    radialBlockedWedges() {
      if (this.steps[2].symmetry.kind !== 'radial') return [];
      const fold = this.steps[2].symmetry.fold;
      const c = this.symmetryCenter;
      const length = this.steps[0].size.value;
      const out = [];
      for (let k = 1; k < fold; k += 1) {
        const a = (k * 2 * Math.PI) / fold;
        const b = ((k + 1) * 2 * Math.PI) / fold;
        const points = [[c, c]];
        const steps = 9;
        for (let i = 0; i <= steps; i += 1) {
          const theta = a + ((b - a) * (i / steps));
          points.push([c + (length * Math.sin(theta)), c - (length * Math.cos(theta))]);
        }
        out.push(points);
      }
      return out;
    },
    // Snap detail under cursor for the polygon-build tool. Resolves the
    // raw snapPoint result back to a {ref, point, isDraftStart, ...} so
    // the commit and preview paths can act on a stable identifier rather
    // than the volatile index into the candidates array. Falls through
    // to the symmetry axis when polygon snap finds nothing closer.
    polygonCursorSnap() {
      if (this.stepCursor !== 2) return null;
      if (this.steps[2].shapeTool !== 'polygon') return null;
      if (!this.steps[2].snapEnabled) return null;
      const refs = this.snapCandidateRefs(null);
      const rings = this.snapCandidateRings(null);
      const pd = this.steps[2].polygonDraft;
      let hasDraftStart = false;
      if (pd && pd.vertices.length > 0) {
        // Append a synthetic 2-vertex "ring" at the start vertex so the
        // edge-projection path naturally returns it as a snap target
        // when the cursor is near. Differentiated by index from the
        // real candidates.
        const start = pd.vertices[0];
        rings.push([start.slice(), start.slice()]);
        hasDraftStart = true;
      }
      const polySnap = editor.snapPoint(
        this.cursorSource, rings, this.steps[2].snapRadius,
      );
      const polyResolved = polySnap ? {
        ...polySnap,
        ref: hasDraftStart && polySnap.polygonIndex === refs.length
          ? null
          : (refs[polySnap.polygonIndex] || null),
        isDraftStart: hasDraftStart && polySnap.polygonIndex === refs.length,
      } : null;

      const axisSnap = this.snapToAxis(this.cursorSource);

      // Pick the closer of the two. Polygon snap takes precedence on a
      // tie because draft-start and existing-vertex snaps carry more
      // semantic weight (anchor / close-target).
      if (polyResolved && axisSnap) {
        return polyResolved.dist <= axisSnap.dist ? polyResolved : axisSnap;
      }
      return polyResolved || axisSnap;
    },
    polygonSnappedCursor() {
      const snap = this.polygonCursorSnap;
      if (snap) return snap.point;
      return this.cursorSource;
    },
    polygonDraftCanClose() {
      const pd = this.steps[2].polygonDraft;
      if (!pd || pd.vertices.length < 3) return false;
      const snap = this.polygonCursorSnap;
      return !!(snap && snap.isDraftStart);
    },
    polygonDraftLinePoints() {
      const pd = this.steps[2].polygonDraft;
      if (!pd) return '';
      return pd.vertices.map(([x, y]) => `${this.resize(x)},${this.resize(y)}`).join(' ');
    },
    // Where the closing edge would go and whether it traces a perimeter
    // (kind === 'same' or 'surface') or just cuts a chord ('chord').
    // The template uses this to render a distinctive preview line so
    // the user knows what the commit will produce before they trigger it.
    polygonClosePreview() {
      const pd = this.steps[2].polygonDraft;
      if (!pd || pd.vertices.length < 3) return null;
      const result = this.computePolygonClose();
      if (!result) return null;
      const last = pd.vertices[pd.vertices.length - 1];
      const start = pd.vertices[0];
      const path = [last, ...result.stitched, start];
      return {
        kind: result.kind,
        points: path.map(([x, y]) => `${this.resize(x)},${this.resize(y)}`).join(' '),
      };
    },
    // Resolve the current selection to the underlying shape object — null
    // if nothing is selected or the indices have drifted (e.g. delete).
    selectedShapeObj() {
      const sel = this.steps[2].selectedShape;
      if (!sel) return null;
      const sector = this.getSector(sel.sectorKey);
      if (!sector || !sector.shapes) return null;
      return sector.shapes[sel.shapeIndex] || null;
    },
    // Points to render for the selected shape — either its committed
    // points or the in-flight transform preview (with snap applied so
    // the visual matches what onMouseup will commit).
    selectedPreviewPoints() {
      const shape = this.selectedShapeObj;
      if (!shape) return null;
      const t = this.steps[2].transform;
      if (!t) return shape.points;
      const sel = this.steps[2].selectedShape;
      let next = null;
      if (t.kind === 'move') {
        const dx = this.cursorSource[0] - t.startCursor[0];
        const dy = this.cursorSource[1] - t.startCursor[1];
        next = editor.translatePolygon(t.originalPoints, dx, dy);
      } else if (t.kind === 'rotate') {
        const angle = this.angleAround(t.center, this.cursorSource)
          - this.angleAround(t.center, t.startCursor);
        next = editor.rotatePolygon(t.originalPoints, t.center, angle);
      } else {
        return shape.points;
      }
      const snapped = this.applySnap(next, sel);
      return snapped || next;
    },
    // Centroid + handle position for the rotate handle. Source coords;
    // template multiplies by resize() for screen-space placement.
    selectedCentroid() {
      const points = this.selectedPreviewPoints;
      if (!points) return null;
      return editor.polygonCentroid(points);
    },
    selectedHandlePosition() {
      const c = this.selectedCentroid;
      const points = this.selectedPreviewPoints;
      if (!c || !points) return null;
      // Handle sits a short distance above the highest point of the
      // current shape — that way it never sits on top of the polygon
      // itself and stays visually anchored to the top.
      const bounds = editor.polygonBounds(points);
      const offset = Math.max(2, (bounds.maxy - bounds.miny) * 0.1);
      return [c[0], bounds.miny - offset];
    },
    // Recompute pairs that overlap. Cheap enough at typical sector counts
    // (< 20 sectors × < 5 shapes each); polygonBounds rejection skips
    // most pairs immediately. Result is a flat array of sector keys that
    // appear in at least one overlapping pair.
    overlappingSectorKeys() {
      const sectors = this.steps[2].sectors;
      const flagged = new Set();
      for (let i = 0; i < sectors.length; i += 1) {
        for (let j = i + 1; j < sectors.length; j += 1) {
          const a = sectors[i];
          const b = sectors[j];
          if (this.sectorPairOverlaps(a, b)) {
            flagged.add(a.key);
            flagged.add(b.key);
          }
        }
      }
      return Array.from(flagged);
    },
  },
  watch: {
    // Debounced — the preview-edges endpoint takes 150-250ms per call
    // (server-side graph generation), and a single slider drag can
    // trigger several genSystem regenerations in quick succession. We
    // collapse those into a single trailing call so the UI stays
    // responsive instead of stacking up backend round-trips.
    extractEdges() {
      if (this._edgesTimer) clearTimeout(this._edgesTimer);
      // If the "Show connections" toggle is off, don't pay for the
      // preview at all — clear what's cached and skip the API call.
      // For very large maps (1500+ systems) the proximity graph
      // returns tens of thousands of edges and the round-trip plus
      // reactivity wiring can hit script-timeout territory.
      if (!this.displayOptions.edges) {
        this.edges = Object.freeze([]);
        return;
      }
      this._edgesTimer = setTimeout(() => {
        this._edgesTimer = null;
        const { systems, blackholes } = this.edgeSource;
        this.$axios.post('/maps/preview-edges', { systems, blackholes }).then(({ data }) => {
          // Freeze deeply before assigning. Without this, Vue 2 would
          // walk every edge and call Object.defineProperty on each
          // nested s1 / s2 / position — at 50k edges that's the source
          // of the O(N²) dep-track and script-timeout the user hit.
          for (let i = 0; i < data.length; i += 1) {
            const e = data[i];
            if (e.s1 && e.s1.position) Object.freeze(e.s1.position);
            if (e.s1) Object.freeze(e.s1);
            if (e.s2 && e.s2.position) Object.freeze(e.s2.position);
            if (e.s2) Object.freeze(e.s2);
            Object.freeze(e);
          }
          this.edges = Object.freeze(data);
        });
      }, 300);
    },
    // Re-evaluate the edges fetch when the toggle flips so turning the
    // setting back on pulls fresh data, and turning it off clears
    // immediately rather than waiting for the next system regenerate.
    'displayOptions.edges': function onEdgesToggle(enabled) {
      if (!enabled) {
        this.edges = Object.freeze([]);
        return;
      }
      // Re-run the watcher inline — same path as a fresh fetch.
      this.$nextTick(() => {
        if (this._edgesTimer) clearTimeout(this._edgesTimer);
        const { systems, blackholes } = this.edgeSource;
        if (!systems || systems.length === 0) return;
        this.$axios.post('/maps/preview-edges', { systems, blackholes }).then(({ data }) => {
          for (let i = 0; i < data.length; i += 1) {
            const e = data[i];
            if (e.s1 && e.s1.position) Object.freeze(e.s1.position);
            if (e.s1) Object.freeze(e.s1);
            if (e.s2 && e.s2.position) Object.freeze(e.s2.position);
            if (e.s2) Object.freeze(e.s2);
            Object.freeze(e);
          }
          this.edges = Object.freeze(data);
        });
      });
    },
  },
  methods: {
    // Builds a self-contained snapshot of the editor state at step 2/3.
    // Triggered by the "Debug export" button — downloads a JSON file
    // and copies to clipboard so the user can share the raw geometry
    // without having to paste console snippets.
    // Best-effort snapshot of editor state. Every field is wrapped in
    // try/catch independently so a single broken accessor (a sector
    // missing `points`, an undefined `density.value` etc.) replaces
    // only that field with { __error: "..." } instead of aborting the
    // whole snapshot. Debug export needs to work on BROKEN states —
    // failing on the broken state defeats the purpose.
    buildDebugSnapshot() {
      const safe = (label, fn) => {
        try { return fn(); } catch (e) { return { __error: `${label}: ${e.message}` }; }
      };
      const cloneSafe = (val) => {
        try {
          // Custom replacer: drops circular refs (Vue reactivity can
          // create them) and coerces BigInt to string so JSON.stringify
          // doesn't throw.
          const seen = new WeakSet();
          return JSON.parse(JSON.stringify(val, (key, v) => {
            if (typeof v === 'bigint') return v.toString();
            if (v !== null && typeof v === 'object') {
              if (seen.has(v)) return '__circular__';
              seen.add(v);
            }
            return v;
          }));
        } catch (e) {
          return { __error: `clone failed: ${e.message}` };
        }
      };
      return {
        timestamp: new Date().toISOString(),
        stepCursor: safe('stepCursor', () => this.stepCursor),
        mapSize: safe('mapSize', () => this.steps[0].size.value),
        symmetryCenter: safe('symmetryCenter', () => this.symmetryCenter),
        step2: safe('step2', () => ({
          drawingMode: safe('drawingMode', () => this.steps[2].drawingMode),
          shapeTool: safe('shapeTool', () => this.steps[2].shapeTool),
          snapEnabled: safe('snapEnabled', () => this.steps[2].snapEnabled),
          snapRadius: safe('snapRadius', () => this.steps[2].snapRadius),
          symmetry: safe('symmetry', () => cloneSafe(this.steps[2].symmetry)),
          selected: safe('selected', () => this.steps[2].selected),
          polygonDraft: safe('polygonDraft', () => cloneSafe(this.steps[2].polygonDraft)),
          sectors: safe('sectors', () => cloneSafe(this.steps[2].sectors)),
        })),
        step3: safe('step3', () => {
          if (this.stepCursor < 3) return null;
          return {
            seed: safe('seed', () => this.steps[3].seed),
            density: safe('density', () => this.steps[3].density.value),
            maxDensity: safe('maxDensity', () => this.steps[3].maxDensity.value),
            points: safe('points', () => this.steps[3].points.value),
            spread: safe('spread', () => this.steps[3].spread.value),
            attenuation: safe('attenuation', () => this.steps[3].attenuation.value),
            systems: safe('systems', () => cloneSafe(this.steps[3].systems)),
          };
        }),
      };
    },
    runEditorTests() {
      const { total, passed } = editorTests.runAllTests();
      if (passed === total) {
        this.$toasted.success(this.$t('page.create.map_editor.tests_pass', { passed, total }));
      } else {
        this.$toasted.error(this.$t('page.create.map_editor.tests_fail', { passed, total }));
      }
    },
    exportDebug() {
      // Build snapshot — even if it throws, fall back to a stub so the
      // export still has SOMETHING in it for diagnosis.
      let data;
      try {
        data = this.buildDebugSnapshot();
      } catch (e) {
        data = { __error: `buildDebugSnapshot threw: ${e.message}`, __stack: e.stack };
      }

      // Stringify with a circular-tolerant + BigInt-tolerant replacer.
      let json;
      try {
        const seen = new WeakSet();
        json = JSON.stringify(data, (key, v) => {
          if (typeof v === 'bigint') return v.toString();
          if (v !== null && typeof v === 'object') {
            if (seen.has(v)) return '__circular__';
            seen.add(v);
          }
          return v;
        }, 2);
      } catch (e) {
        json = `{"__error":"JSON.stringify failed: ${(e.message || '').replace(/"/g, '\\"')}"}`;
      }

      // 1) Download — failure here doesn't block console log or clipboard.
      try {
        const blob = new Blob([json], { type: 'application/json' });
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = `forge-debug-${Date.now()}.json`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);
      } catch (e) {
        // eslint-disable-next-line no-console
        console.warn('[debug-export] download failed', e);
      }
      // 2) Log to console — always reachable.
      try {
        // eslint-disable-next-line no-console
        console.log('[debug-export]', data);
      } catch (_) { /* ignore */ }
      // 3) Best-effort clipboard write.
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(json).then(
            () => this.$toasted.success(this.$t('page.create.map_editor.debug_export_done')),
            () => this.$toasted.success(this.$t('page.create.map_editor.debug_export_done_no_clipboard')),
          );
        } else {
          this.$toasted.success(this.$t('page.create.map_editor.debug_export_done_no_clipboard'));
        }
      } catch (_) { /* ignore */ }
    },
    async nextStep() {
      if (this.stepCursor === 0) {
        if (!this.steps[0].size.value) {
          this.$toastError(this.$t('page.create.map_editor.toast_missing_size'));
          return false;
        }

        this.steps[1].seed = this.newSeed();
        this.genVoronoi();
      } else if (this.stepCursor === 1) {
        if (this.steps[1].triangles.length < 1) {
          this.$toastError(this.$t('page.create.map_editor.toast_no_triangles'));
          return false;
        }
      } else if (this.stepCursor === 2) {
        // assembleTriangles emits a sector for every entry that has
        // either a shape primitive OR at least one assigned triangle;
        // entries with neither are dropped silently. Re-check the
        // post-assembly count to reject "no usable sectors" maps.
        const { sectors, errors } = editor.assembleTriangles(this.steps[2].sectors);
        errors.forEach((err) => this.$toastError(this.$t(err.key, err.params)));

        if (sectors.length < 2) {
          this.$toastError(this.$t('page.create.map_editor.toast_insufficient_sectors'));
          return false;
        }

        // Auto-mirror: when symmetry is on, each sector whose centroid
        // lies off the relevant axis spawns mirror copies as new
        // sectors. Each mirror records sourceKey + mirrorKind so the
        // subsequent genSystem call can copy + reflect the source's
        // systems rather than re-rolling, keeping the symmetric layout
        // visually consistent across regenerations.
        //
        // Canonicalize first so on-axis vertices land exactly on the
        // axis and shared borders use identical coordinates — without
        // this step, tiny float drift in adjacent sectors propagates
        // into the mirror as visible asymmetric artifacts.
        const symmetry = this.steps[2].symmetry;
        const expanded = sectors.slice();
        if (symmetry && symmetry.kind !== 'none') {
          const center = this.steps[0].size.value / 2;
          const eps = this.steps[2].snapRadius;
          editor.canonicalizeSharedVertices(sectors, symmetry, center, eps);

          // Collect every mirror spec first so we know how many names
          // to ask for, then fetch them all in one /name/sector/N call.
          const mirrorSpecs = [];
          sectors.forEach((sector) => {
            const mirrors = editor.generateMirrorSectors(sector, symmetry, center, eps);
            mirrors.forEach((m) => mirrorSpecs.push({ sector, mirror: m }));
          });

          let names = [];
          if (mirrorSpecs.length > 0) {
            try {
              const { data } = await this.$axios.get(`/name/sector/${mirrorSpecs.length}`);
              names = Array.isArray(data) ? data : [];
            } catch (_err) {
              // Fall through to the source-plus-suffix naming below.
              names = [];
            }
          }

          let nextKey = sectors.reduce((m, s) => Math.max(m, s.key), 0) + 1;
          mirrorSpecs.forEach(({ sector, mirror: m }, idx) => {
            const colorIdx = ((nextKey - 1) % 9) + 1;
            const generatedName = names[idx]
              || `${sector.name} (${m.kind.toUpperCase()})`;
            expanded.push({
              key: nextKey,
              name: generatedName,
              color: `editor-color-${colorIdx}`,
              shapes: [],
              points: m.points,
              points03: editor.offsetPolygon(m.points, 0.3),
              points05: editor.offsetPolygon(m.points, 0.5),
              points25: editor.offsetPolygon(m.points, 2.5),
              area: Math.abs(editor.polygonArea(m.points)),
              centroid: editor.polygonCentroid(m.points),
              systems: [],
              sourceKey: sector.key,
              mirrorKind: m.kind,
              // Captured for radial mirrors so genSystem can rotate the
              // source's systems by the same angle without re-deriving
              // it from the fold count.
              mirrorAngle: m.angle,
            });
            nextKey += 1;
          });
        }

        // Freeze the static geometry arrays before assigning. Vue 2's
        // reactivity walks every nested object on assignment, and the
        // points / points03 / points05 / points25 arrays are read-only
        // after canonicalize + mirror generation. Frozen arrays are
        // skipped by `observe`, saving significant tracking overhead on
        // the step-3 SVG render path.
        expanded.forEach((s) => {
          if (s.points) Object.freeze(s.points);
          if (s.points03) Object.freeze(s.points03);
          if (s.points05) Object.freeze(s.points05);
          if (s.points25) Object.freeze(s.points25);
        });
        this.steps[1].triangles = [];
        this.steps[2].sectors = expanded;
        this.steps[2].draft = null;
        this.steps[2].polygonDraft = null;
        this.steps[2].shapeTool = null;
        this.steps[3].seed = this.newSeed();
        this.genSystem();
      } else if (this.stepCursor === 3) {
        const emptySector = this.steps[2].sectors.find((s) => s.systems.length === 0);
        if (emptySector) {
          this.$toastError(this.$t('page.create.map_editor.toast_empty_sector'));
          return false;
        }
      } else if (this.stepCursor === 4) {
        const sectors = this.steps[2].sectors.map((s) => ({
          key: s.key,
          name: s.name,
          area: s.area,
          centroid: s.centroid,
          points: s.points,
          points03: s.points03,
          systems: s.systems,
          systemCount: s.systemCount,
        }));

        const gameData = {
          size: this.steps[0].size.value,
          systems: this.steps[3].systems,
          sectors,
          blackholes: this.steps[4].blackholes,
        };

        this.steps[5].map.game_data = gameData;
        this.steps[5].map.game_metadata.system_number = this.steps[3].systems.length;
        this.steps[5].map.game_metadata.sector_number = sectors.length;
        this.steps[5].map.game_metadata.size = this.steps[0].size.value;

        this.steps[1].seed = '';
        this.steps[2].sectors = [];
        this.steps[2].selected = undefined;
        this.steps[3].seed = '';
        this.steps[3].systems = [];
        this.steps[4].blackholes = [];
        this.steps[4].deleteMode = false;
        this.steps[4].blackholeMode = false;
      }

      this.stepCursor += 1;
    },
    async create() {
      if (this.isValid) {
        this.waiting = true;

        try {
          await this.$axios.post('/maps', { map: this.steps[5].map });
          // Thumbnail is rendered server-side from the persisted
          // game_data — see RC.Scenarios.regenerate_map_thumbnail.
          this.$toasted.success(this.$t('page.create.map_editor.toast_created'));
          this.$router.push('/create/maps');
        } catch (err) {
          this.$toastError(this.$t('page.create.common.error_generic'));
        }

        this.waiting = false;
      }
    },
    async update() {
      if (this.isValid) {
        this.waiting = true;
        const map = this.steps[5].map;

        try {
          await this.$axios.put(`/maps/${map.id}`, { map });
          this.$toasted.success(this.$t('page.create.map_editor.toast_saved'));
          this.$router.push('/create/maps');
        } catch (err) {
          this.$toastError(this.$t('page.create.common.error_generic'));
        }

        this.waiting = false;
      }
    },
    async publish() {
      // Stage 2 — flip published_at on the server, then refresh the local
      // map so the button vanishes without a full reload. The confirm is
      // there because publishing is the one-way-ish move (you can still
      // edit afterward, but every player sees it the moment you click).
      if (!window.confirm(this.$t('page.create.common.publish_confirm'))) return;

      this.waiting = true;
      const map = this.steps[5].map;

      try {
        const { data } = await this.$axios.put(`/maps/${map.id}/publish`);
        this.steps[5].map = data;
        this.$toasted.success(this.$t('page.create.map_editor.toast_saved'));
      } catch (err) {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }

      this.waiting = false;
    },
    formatDate(iso) {
      if (!iso) return '';
      return new Date(iso).toLocaleDateString();
    },
    async react(kind) {
      try {
        await this.$axios.post(`/maps/${this.steps[5].map.id}/folders/${kind}`);
        this.$set(this.steps[5].map, kind, (this.steps[5].map[kind] || 0) + 1);
      } catch (err) {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }
    },
    async destroy() {
      this.waiting = true;

      try {
        await this.$axios.delete(`/maps/${this.steps[5].map.id}`);
        this.$toasted.success(this.$t('page.create.map_editor.toast_deleted'));
        this.$router.push('/create/maps');
      } catch (err) {
        this.$toastError(this.$t('page.create.common.error_generic'));
      }

      this.waiting = false;
    },
    genVoronoi() {
      this.steps[1].triangles = editor.genVoronoi(
        new Prando(this.steps[1].seed),
        this.steps[0].size.value,
        this.steps[1].grid.value,
      );
    },
    genSystem() {
      this.edges = [];
      // Only the originals get fed through the placement RNG. Mirror
      // sectors copy their source's positions (reflected) so the
      // symmetric layout stays exact — re-rolling the mirror side
      // would produce visible asymmetry on every regenerate.
      const originals = this.steps[2].sectors.filter((s) => !s.sourceKey);
      const mirrors = this.steps[2].sectors.filter((s) => s.sourceKey);

      const originalSystems = editor.genSystem(
        new Prando(this.steps[3].seed),
        originals,
        this.data.stellar_system,
        {
          density: this.steps[3].density.value,
          maxDensity: this.steps[3].maxDensity.value,
          points: this.steps[3].points.value,
          spread: this.steps[3].spread.value,
          attenuation: this.steps[3].attenuation.value,
        },
      );

      const center = this.steps[0].size.value / 2;
      let nextId = originalSystems.length;
      const mirrorSystems = [];
      mirrors.forEach((mirror) => {
        mirror.systems = [];
        const source = originals.find((s) => s.key === mirror.sourceKey);
        if (!source) return;
        const mirrorOp = typeof mirror.mirrorAngle === 'number'
          ? { rotate: mirror.mirrorAngle }
          : mirror.mirrorKind;
        const reflected = editor.mirrorSystems(source.systems, mirrorOp, center);
        reflected.forEach((sys) => {
          nextId += 1;
          const placed = { key: nextId, position: sys.position, type: sys.type };
          mirror.systems.push(placed);
          mirrorSystems.push(placed);
        });
      });

      // Freeze the position objects on each system. systems[].position
      // is read-only after placement; freezing prevents Vue from making
      // it reactive on assignment, which saves O(N) defineProperty calls
      // and dep-track wiring per regeneration. System keys, types, and
      // sector.systems arrays stay mutable because step 4's blackhole
      // tool deletes from them.
      const allSystems = originalSystems.concat(mirrorSystems);
      for (let i = 0; i < allSystems.length; i += 1) {
        if (allSystems[i].position) Object.freeze(allSystems[i].position);
      }
      this.steps[3].systems = allSystems;
    },
    // v-model on a type="number" input yields an empty string when
    // cleared, a string for partial typing, and a number when committed.
    // Normalize to either a positive integer or null so the dispatcher
    // in editor.genSystem can decide cleanly between exact-count and
    // density placement.
    onSectorCountChange(sector) {
      const raw = sector.systemCount;
      const n = parseInt(raw, 10);
      sector.systemCount = (Number.isInteger(n) && n > 0) ? n : null;
      this.genSystem();
    },
    getSector(key) {
      return this.steps[2].sectors.find((s) => s.key === key);
    },
    addSector() {
      this.$axios.get('/name/sector/1').then((response) => {
        const id = this.steps[2].cursor;
        const sector = editor.createSector(id, response.data[0]);

        this.steps[2].cursor += 1;
        this.steps[2].sectors.push(sector);
        this.selectSector(id);
      }).catch((err) => {
        this.$toastError(`${this.$t('page.create.common.error_generic')}: ${err}`);
      });
    },
    removeSector(key) {
      const sector = this.getSector(key);

      this.steps[1].triangles = this.steps[1].triangles.map((triangle) => {
        if (sector.triangles.find((t) => triangle.key === t.key)) {
          triangle.color = undefined;
        }

        return triangle;
      });

      this.steps[2].sectors = this.steps[2].sectors.filter((s) => s.key !== key);
    },
    selectSector(key) {
      this.steps[2].selected = this.steps[2].selected === key ? undefined : key;
    },
    getBlackhole(key) {
      return this.steps[4].blackholes.find((b) => b.key === key);
    },
    addBlackhole(x, y, radius) {
      this.$axios.get('/name/sector/1').then((response) => {
        const id = this.steps[4].cursor;
        const blackhole = editor.createBlackhole(id, response.data[0], { x, y }, radius);

        this.steps[4].cursor += 1;
        this.steps[4].blackholes.push(blackhole);
      }).catch((err) => {
        this.$toastError(`${this.$t('page.create.common.error_generic')}: ${err}`);
      });
    },
    removeBlackhole(key) {
      this.steps[4].blackholes = this.steps[4].blackholes.filter((b) => b.key !== key);
    },
    hoverTriangle(key, event) {
      if (event.ctrlKey) {
        this.toggleTriangleToSector(key, false);
      }
    },
    toggleTriangleToSector(key, toggle = true) {
      if (this.steps[2].selected) {
        const { triangles, sectors } = editor.toggleTriangleToSector(
          key,
          toggle,
          this.getSector(this.steps[2].selected),
          this.steps[1].triangles,
          this.steps[2].sectors,
        );

        this.steps[1].triangles = triangles;
        this.steps[2].sectors = sectors;
      }
    },
    resize(value) {
      return Math.round(value * (this.container.width / this.steps[0].size.value) * 100) / 100;
    },
    rresize(value) {
      return value * (this.steps[0].size.value / this.container.width);
    },
    newSeed(size = 8) {
      return Math.random().toString(36).substring(size);
    },
    edgesPath(edges) {
      return edges.reduce((acc, edge) => {
        const { s1, s2 } = edge;
        return acc
          + `M ${this.resize(s1.position.x)} ${this.resize(s1.position.y)} `
          + `L ${this.resize(s2.position.x)} ${this.resize(s2.position.y)}`;
      }, '');
    },
    deleteSystemsInRadius(x, y, radius) {
      const toRemove = this.steps[3].systems
        .filter((s) => {
          const sx = this.resize(s.position.x);
          const sy = this.resize(s.position.y);

          return ((sx - x) ** 2) + ((sy - y) ** 2) < radius ** 2;
        })
        .map((s) => s.key);

      this.steps[3].systems = this.steps[3].systems.filter((s) => !toRemove.includes(s.key));
      this.steps[2].sectors = this.steps[2].sectors.map((sector) => {
        sector.systems = sector.systems.filter((s) => !toRemove.includes(s.key));
        return sector;
      });
    },
    onClick() {
      const x = this.mouse.x - this.container.x;
      const y = this.mouse.y - this.container.y;
      const inCanvas = x > 0 && x < this.container.width && y > 0 && y < this.container.width;

      // Move keyboard focus off any input field (e.g. sector rename)
      // when the user clicks the canvas. Without this, focus stays on
      // the input and the window-level keydown handler skips Enter /
      // Backspace because event.target reads as a form field.
      if (inCanvas
        && document.activeElement
        && (document.activeElement.tagName === 'INPUT'
          || document.activeElement.tagName === 'TEXTAREA')) {
        document.activeElement.blur();
      }

      if (this.stepCursor === 2 && this.steps[2].drawingMode === 'shapes' && inCanvas) {
        this.onShapeClick(x, y);
        return;
      }

      if (this.stepCursor === 4) {
        if (this.steps[4].deleteMode) {
          const radius = this.resize(this.steps[4].deleteRadius.value);

          this.deleteSystemsInRadius(x, y, radius);
        } else if (this.steps[4].blackholeMode) {
          if (inCanvas) {
            const radius = this.resize(this.steps[4].blackholeRadius.value);

            this.addBlackhole(this.rresize(x), this.rresize(y), this.steps[4].blackholeRadius.value);
            this.deleteSystemsInRadius(x, y, radius + 5);
          }
        }
      }
    },
    // Click handler for draw tools. Select short-circuits (mousedown path
    // on shape polygons handles it). Rect is two-click. Polygon is multi-
    // click + Enter/close-on-start.
    onShapeClick(x, y) {
      const tool = this.steps[2].shapeTool;
      if (!tool || tool === 'select') return;

      const selected = this.steps[2].selected;
      if (!selected) {
        this.$toastError(this.$t('page.create.map_editor.toast_select_sector_first'));
        return;
      }

      const px = this.rresize(x);
      const py = this.rresize(y);

      if (tool === 'polygon') {
        this.onPolygonClick([px, py]);
        return;
      }

      // Rectangle: two-click anchor → opposite-corner. Block clicks
      // outside the canonical drawing area when symmetry is on — the
      // cross-hatch overlay makes the boundary visible.
      if (this.isPointBlocked([px, py])) return;
      if (!this.steps[2].draft) {
        this.steps[2].draft = { anchor: [px, py] };
        return;
      }
      const anchor = this.steps[2].draft.anchor;
      const dx = px - anchor[0];
      const dy = py - anchor[1];
      if (Math.abs(dx) < 1 || Math.abs(dy) < 1) {
        this.steps[2].draft = null;
        return;
      }
      let points = editor.genRect(anchor, [px, py]);
      const snapped = this.applySnap(points, null);
      if (snapped) points = snapped;
      this.commitNewShape({ kind: 'rect', points, params: {} });
      this.steps[2].draft = null;
    },
    onPolygonClick(point) {
      // Resolve snap (vertex/edge of existing shape, or close-on-start).
      const snap = this.polygonCursorSnap;
      const pd = this.steps[2].polygonDraft;

      // Close on start vertex (with ≥3 placed) — exact gesture the user
      // performs when they click back on the first dot they placed.
      if (snap && snap.isDraftStart && pd && pd.vertices.length >= 3) {
        this.closePolygonDraft();
        return;
      }

      const placed = snap && !snap.isDraftStart ? snap.point.slice() : point;
      // Reject vertex placement outside the canonical drawing area when
      // symmetry is on. Snap-to-axis still works — the axis is on the
      // boundary and is treated as allowed.
      if (this.isPointBlocked(placed)) return;
      const anchor = snap && !snap.isDraftStart && snap.ref
        ? {
          ref: snap.ref,
          kind: snap.kind,
          vertexIndex: snap.vertexIndex,
          edgeIndex: snap.edgeIndex,
          t: snap.t,
          // Storing the snapped coordinate is required by the surface-
          // graph close: buildSurfaceGraph subdivides edges and resolves
          // anchor positions through findOrCreate(anchor.point). Without
          // this, the cross-polygon close throws and silently falls
          // back to a chord.
          point: snap.point.slice(),
        }
        : null;

      if (!pd) {
        this.steps[2].polygonDraft = { vertices: [placed], anchors: [anchor] };
        return;
      }
      pd.vertices.push(placed);
      pd.anchors.push(anchor);
    },
    // Compute what closing the polygon would produce — used both for
    // the live preview (so the user sees chord vs traced before
    // committing) and for the actual commit. Returns {stitched, kind}
    // where kind is 'same' | 'surface' | 'chord' and stitched is the
    // list of intermediate points to insert between the last vertex
    // and the start (empty for chord).
    computePolygonClose() {
      const pd = this.steps[2].polygonDraft;
      if (!pd || pd.vertices.length < 3) return null;

      const startAnchor = pd.anchors[0];
      const lastAnchor = pd.anchors[pd.anchors.length - 1];
      const sameRef = (a, b) => a && b
        && a.sectorKey === b.sectorKey
        && a.shapeIndex === b.shapeIndex;

      if (startAnchor && lastAnchor && startAnchor.ref && lastAnchor.ref
        && sameRef(startAnchor.ref, lastAnchor.ref)) {
        const otherSector = this.getSector(startAnchor.ref.sectorKey);
        const otherShape = otherSector && otherSector.shapes
          && otherSector.shapes[startAnchor.ref.shapeIndex];
        if (otherShape) {
          const stitched = editor.perimeterWalk(otherShape.points, lastAnchor, startAnchor);
          return { stitched, kind: 'same' };
        }
      } else if (startAnchor && lastAnchor && startAnchor.ref && lastAnchor.ref) {
        try {
          // Include every placed shape as a candidate bridge in the
          // surface graph. Dijkstra finds the genuine shortest path
          // through whatever chain of shared edges/vertices exists;
          // the user sees the resulting trace as a dashed preview and
          // the close-button badge labels it Trace vs Chord, so they
          // can verify before committing rather than us preemptively
          // restricting the candidate set.
          const allShapes = [];
          this.steps[2].sectors.forEach((s) => {
            (s.shapes || []).forEach((shape, idx) => {
              allShapes.push({
                ref: { sectorKey: s.key, shapeIndex: idx },
                points: shape.points,
              });
            });
          });
          const findIndex = (ref) => allShapes.findIndex((s) => sameRef(s.ref, ref));
          const fromIdx = findIndex(lastAnchor.ref);
          const toIdx = findIndex(startAnchor.ref);
          if (fromIdx >= 0 && toIdx >= 0) {
            const polygons = allShapes.map((s) => s.points);
            const fromAnchorWithIdx = { ...lastAnchor, polygonIndex: fromIdx };
            const toAnchorWithIdx = { ...startAnchor, polygonIndex: toIdx };
            // eps tracks the user's snap radius — same slider controls
            // both draw-time snap and graph-connection sensitivity, so
            // "polygons placed within snap range" trace by default.
            const graph = editor.buildSurfaceGraph(
              polygons, fromAnchorWithIdx, toAnchorWithIdx,
              this.steps[2].snapRadius,
            );
            const path = editor.shortestPathOnSurface(
              graph, graph.fromNodeId, graph.toNodeId,
            );
            if (path) return { stitched: path, kind: 'surface' };
          }
        } catch (err) {
          // eslint-disable-next-line no-console
          console.warn('surface walk failed, using chord close', err);
        }
      }
      return { stitched: [], kind: 'chord' };
    },
    closePolygonDraft() {
      const pd = this.steps[2].polygonDraft;
      if (!pd || pd.vertices.length < 3) return;
      const selected = this.steps[2].selected;
      if (!selected) {
        this.$toastError(this.$t('page.create.map_editor.toast_select_sector_first'));
        return;
      }
      const result = this.computePolygonClose();
      if (!result) return;
      const ring = pd.vertices.map((p) => p.slice());
      result.stitched.forEach((p) => ring.push(p));
      ring.push(ring[0].slice());
      this.commitNewShape({ kind: 'polygon', points: ring, params: {} });
      this.steps[2].polygonDraft = null;
    },
    // Shared commit path for rect and polygon — append to the active
    // sector's shapes[] (clearing any triangle assignment first).
    commitNewShape(shape) {
      const selected = this.steps[2].selected;
      const sector = this.getSector(selected);
      if (!sector) return;
      if (!sector.shapes) this.$set(sector, 'shapes', []);
      sector.shapes.push(shape);
      if (sector.triangles && sector.triangles.length > 0) {
        sector.triangles.forEach((t) => { t.color = undefined; });
        sector.triangles = [];
      }
    },
    // Window-level mousedown is the deselect target for the select tool.
    // Individual shape mousedowns call event.stopPropagation, so this only
    // fires when the cursor went down on empty canvas.
    onMousedown(event) {
      if (this.stepCursor !== 2) return;
      if (this.steps[2].drawingMode !== 'shapes') return;
      if (this.steps[2].shapeTool !== 'select') return;

      const x = event.clientX - this.container.x;
      const y = event.clientY - this.container.y;
      const inCanvas = x > 0 && x < this.container.width && y > 0 && y < this.container.width;
      if (!inCanvas) return;

      this.steps[2].selectedShape = null;
    },
    onShapeMousedown(sectorKey, shapeIndex, event) {
      if (this.steps[2].shapeTool !== 'select') return;
      event.preventDefault();
      // Select first (always), then start a move transform. If the user
      // mouses up without moving, the commit is a no-op translation —
      // selection persists, nothing else changes.
      this.steps[2].selectedShape = { sectorKey, shapeIndex };
      const sector = this.getSector(sectorKey);
      const shape = sector && sector.shapes && sector.shapes[shapeIndex];
      if (!shape) return;
      this.steps[2].transform = {
        kind: 'move',
        startCursor: this.cursorSource.slice(),
        originalPoints: shape.points.map((p) => p.slice()),
      };
    },
    onHandleMousedown(event) {
      const sel = this.steps[2].selectedShape;
      if (!sel) return;
      event.preventDefault();
      const sector = this.getSector(sel.sectorKey);
      const shape = sector && sector.shapes && sector.shapes[sel.shapeIndex];
      if (!shape) return;
      this.steps[2].transform = {
        kind: 'rotate',
        center: editor.polygonCentroid(shape.points),
        startCursor: this.cursorSource.slice(),
        originalPoints: shape.points.map((p) => p.slice()),
      };
    },
    onMouseup() {
      // Commit any in-flight transform. The preview points the template
      // was rendering get written back to the shape; the transform state
      // is cleared. Overlap is non-blocking — the overlappingSectorKeys
      // computed surfaces it as a banner.
      const t = this.steps[2].transform;
      if (!t) return;
      const sel = this.steps[2].selectedShape;
      if (!sel) { this.steps[2].transform = null; return; }
      const sector = this.getSector(sel.sectorKey);
      const shape = sector && sector.shapes && sector.shapes[sel.shapeIndex];
      if (!shape) { this.steps[2].transform = null; return; }

      let next;
      if (t.kind === 'move') {
        const dx = this.cursorSource[0] - t.startCursor[0];
        const dy = this.cursorSource[1] - t.startCursor[1];
        next = editor.translatePolygon(t.originalPoints, dx, dy);
      } else if (t.kind === 'rotate') {
        const angle = this.angleAround(t.center, this.cursorSource)
          - this.angleAround(t.center, t.startCursor);
        next = editor.rotatePolygon(t.originalPoints, t.center, angle);
      }
      if (next) {
        const snapped = this.applySnap(next, sel);
        shape.points = snapped || next;
      }
      this.steps[2].transform = null;
    },
    angleAround(center, point) {
      return Math.atan2(point[1] - center[1], point[0] - center[0]);
    },
    // Polygons to snap against — every placed shape except the one
    // identified by `exclude` ({sectorKey, shapeIndex}). Pass null when
    // drawing a new shape (nothing to exclude).
    snapCandidateRings(exclude) {
      const out = [];
      this.steps[2].sectors.forEach((sector) => {
        (sector.shapes || []).forEach((shape, idx) => {
          if (exclude
            && exclude.sectorKey === sector.key
            && exclude.shapeIndex === idx) return;
          out.push(shape.points);
        });
      });
      return out;
    },
    // Parallel array of {sectorKey, shapeIndex} refs so a snap result's
    // polygonIndex (into the rings array) can be resolved back to its
    // owning shape — needed for perimeter walking at polygon-close time.
    snapCandidateRefs(exclude) {
      const out = [];
      this.steps[2].sectors.forEach((sector) => {
        (sector.shapes || []).forEach((shape, idx) => {
          if (exclude
            && exclude.sectorKey === sector.key
            && exclude.shapeIndex === idx) return;
          out.push({ sectorKey: sector.key, shapeIndex: idx });
        });
      });
      return out;
    },
    applySnap(points, exclude) {
      if (!this.steps[2].snapEnabled) return null;
      const candidates = this.snapCandidateRings(exclude);
      if (candidates.length === 0) return null;
      return editor.snapPolygon(points, candidates, this.steps[2].snapRadius);
    },
    // Is `point` outside the canonical drawing area? Canonical = the
    // upper-left quadrant / half-plane for the active symmetry kind.
    // Axis itself is allowed (axis-snapped vertices generate self-
    // mirroring sectors). Vertices just barely on the wrong side are
    // treated as blocked so a misclick doesn't seed a non-mirrorable
    // shape — the user can move the cursor onto the axis if they want
    // that vertex.
    isPointBlocked(point) {
      const kind = this.steps[2].symmetry.kind;
      if (kind === 'none') return false;
      const center = this.symmetryCenter;
      if (kind === 'radial') {
        const fold = this.steps[2].symmetry.fold;
        const dx = point[0] - center;
        const dy = point[1] - center;
        if ((dx * dx) + (dy * dy) < 1e-6) return false;
        // Treat points within onSpokeEps of any spoke as on the shared
        // boundary — allowed regardless of which wedge they angularly
        // belong to. Without this, snap-to-spoke produces points that
        // fall exactly on the wedge boundary at angle = 2π/fold, which
        // the canonical-wedge test (angle < 2π/fold) would reject.
        const onSpokeEps = 0.1;
        const onSpokeEpsSq = onSpokeEps * onSpokeEps;
        for (let k = 0; k < fold; k += 1) {
          const theta = (k * 2 * Math.PI) / fold;
          const dirX = Math.sin(theta);
          const dirY = -Math.cos(theta);
          const t = (dx * dirX) + (dy * dirY);
          if (t < 0) continue;
          const projX = center + (t * dirX);
          const projY = center + (t * dirY);
          const ddx = point[0] - projX;
          const ddy = point[1] - projY;
          if ((ddx * ddx) + (ddy * ddy) < onSpokeEpsSq) return false;
        }
        const angle = ((Math.atan2(dx, -dy)) + (2 * Math.PI)) % (2 * Math.PI);
        return angle >= (2 * Math.PI) / fold;
      }
      const wantsV = kind === 'vertical' || kind === 'both';
      const wantsH = kind === 'horizontal' || kind === 'both';
      if (wantsV && point[0] > center) return true;
      if (wantsH && point[1] > center) return true;
      return false;
    },
    // Snap a point onto the active symmetry axis (or axis intersection).
    // Returns {point, dist, kind: 'axis'} if any axis is within snap
    // radius of `point`, else null. ref stays null — axis snaps are
    // positional only and don't participate in close path-finding.
    snapToAxis(point) {
      const kind = this.steps[2].symmetry.kind;
      if (kind === 'none' || !this.steps[2].snapEnabled) return null;
      const center = this.symmetryCenter;
      const radius = this.steps[2].snapRadius;

      if (kind === 'radial') {
        const fold = this.steps[2].symmetry.fold;
        const dx = point[0] - center;
        const dy = point[1] - center;
        const distToCenter = Math.sqrt((dx * dx) + (dy * dy));
        if (distToCenter <= radius) {
          return {
            point: [center, center], dist: distToCenter,
            ref: null, kind: 'axis', isDraftStart: false,
          };
        }
        // For each spoke, project point onto it. Pick the closest
        // projection within snap radius.
        let best = null;
        for (let k = 0; k < fold; k += 1) {
          const theta = (k * 2 * Math.PI) / fold;
          // Spoke direction in screen coords: (sin θ, -cos θ).
          const dirX = Math.sin(theta);
          const dirY = -Math.cos(theta);
          // Project point - center onto the spoke direction.
          const t = (dx * dirX) + (dy * dirY);
          if (t < 0) continue; // spoke only extends in the positive direction
          const projX = center + (t * dirX);
          const projY = center + (t * dirY);
          const ddx = point[0] - projX;
          const ddy = point[1] - projY;
          const d = Math.sqrt((ddx * ddx) + (ddy * ddy));
          if (d <= radius && (!best || d < best.dist)) {
            best = {
              point: [projX, projY], dist: d,
              ref: null, kind: 'axis', isDraftStart: false,
            };
          }
        }
        return best;
      }

      const wantsV = kind === 'vertical' || kind === 'both';
      const wantsH = kind === 'horizontal' || kind === 'both';
      const dV = wantsV ? Math.abs(point[0] - center) : Infinity;
      const dH = wantsH ? Math.abs(point[1] - center) : Infinity;
      if (dV > radius && dH > radius) return null;

      if (dV <= radius && dH <= radius) {
        return {
          point: [center, center],
          dist: Math.sqrt((dV * dV) + (dH * dH)),
          ref: null, kind: 'axis', isDraftStart: false,
        };
      }
      if (dV <= radius) {
        return {
          point: [center, point[1]],
          dist: dV,
          ref: null, kind: 'axis', isDraftStart: false,
        };
      }
      return {
        point: [point[0], center],
        dist: dH,
        ref: null, kind: 'axis', isDraftStart: false,
      };
    },
    sectorPairOverlaps(a, b) {
      const aShapes = (a.shapes && a.shapes.length > 0)
        ? a.shapes.map((s) => s.points)
        : (a.points ? [a.points] : []);
      const bShapes = (b.shapes && b.shapes.length > 0)
        ? b.shapes.map((s) => s.points)
        : (b.points ? [b.points] : []);
      for (let i = 0; i < aShapes.length; i += 1) {
        for (let j = 0; j < bShapes.length; j += 1) {
          if (editor.shapesIntersect(aShapes[i], bShapes[j])) return true;
        }
      }
      return false;
    },
    deleteSelectedShape() {
      const sel = this.steps[2].selectedShape;
      if (!sel) return;
      const sector = this.getSector(sel.sectorKey);
      if (!sector || !sector.shapes) return;
      sector.shapes.splice(sel.shapeIndex, 1);
      this.steps[2].selectedShape = null;
      this.steps[2].transform = null;
    },
    onKeydown(event) {
      const tag = (event.target && event.target.tagName) || '';
      const inField = tag === 'INPUT' || tag === 'TEXTAREA';

      if (event.key === 'Escape') {
        if (this.steps[2].transform) {
          this.steps[2].transform = null;
          return;
        }
        if (this.steps[2].polygonDraft) {
          this.steps[2].polygonDraft = null;
          return;
        }
        if (this.steps[2].draft) {
          this.steps[2].draft = null;
          return;
        }
        if (this.steps[2].selectedShape) {
          this.steps[2].selectedShape = null;
        }
        return;
      }
      if (event.key === 'Enter'
        && !inField
        && this.stepCursor === 2
        && this.steps[2].shapeTool === 'polygon'
        && this.steps[2].polygonDraft
        && this.steps[2].polygonDraft.vertices.length >= 3) {
        event.preventDefault();
        this.closePolygonDraft();
        return;
      }
      // Backspace during a polygon draft pops the last placed vertex —
      // standard CAD editor UX. Falls through to delete-selected-shape
      // when no draft is in progress.
      if (event.key === 'Backspace'
        && !inField
        && this.stepCursor === 2
        && this.steps[2].shapeTool === 'polygon'
        && this.steps[2].polygonDraft
        && this.steps[2].polygonDraft.vertices.length > 0) {
        event.preventDefault();
        const pd = this.steps[2].polygonDraft;
        pd.vertices.pop();
        pd.anchors.pop();
        if (pd.vertices.length === 0) this.steps[2].polygonDraft = null;
        return;
      }
      if ((event.key === 'Delete' || event.key === 'Backspace')
        && this.stepCursor === 2
        && this.steps[2].selectedShape
        && !inField) {
        event.preventDefault();
        this.deleteSelectedShape();
      }
    },
    onDrawingModeChange() {
      // Switching between Voronoi/Shapes modes invalidates any in-flight
      // shape draft and clears the active tool — otherwise the next mode
      // switch could leave a half-committed anchor floating on the canvas.
      this.steps[2].draft = null;
      this.steps[2].polygonDraft = null;
      this.steps[2].shapeTool = null;
      this.steps[2].selectedShape = null;
      this.steps[2].transform = null;
    },
    onShapeToolChange() {
      this.steps[2].draft = null;
      this.steps[2].polygonDraft = null;
      this.steps[2].transform = null;
      // Selection persists across tool switches so Delete/Backspace
      // continues to act on the previously-clicked shape even while
      // the user is mid-draw with a different tool. The transform
      // handles (rotate, drag) only render when shapeTool === 'select'
      // so the visual stays clean.
    },
    shapePolygonAttr(points) {
      return points.map(([x, y]) => `${this.resize(x)},${this.resize(y)}`).join(' ');
    },
    placedShapePoints(placed) {
      // Render the in-flight transform preview for the selected shape;
      // every other shape renders its committed points unchanged.
      if (this.isShapeSelected(placed) && this.steps[2].transform) {
        return this.shapePolygonAttr(this.selectedPreviewPoints);
      }
      return this.shapePolygonAttr(placed.shape.points);
    },
    isShapeSelected(placed) {
      const sel = this.steps[2].selectedShape;
      if (!sel) return false;
      return sel.sectorKey === placed.sectorKey && sel.shapeIndex === placed.shapeIndex;
    },
    setContainerSize() {
      const box = this.$refs.container.getBoundingClientRect();

      this.container = {
        x: box.left + 25,
        y: box.top + 25,
        width: this.$refs.container.clientWidth - (25 * 2),
      };
    },
    setMousePosition(event) {
      this.mouse = {
        x: event.clientX,
        y: event.clientY,
      };
    },
  },
  async mounted() {
    this.setContainerSize();
    window.addEventListener('resize', this.setContainerSize);
    window.addEventListener('mousemove', this.setMousePosition);
    window.addEventListener('click', this.onClick);
    window.addEventListener('keydown', this.onKeydown);
    window.addEventListener('mousedown', this.onMousedown);
    window.addEventListener('mouseup', this.onMouseup);

    if (this.$route.params.id !== 'new') {
      try {
        const { data } = await this.$axios.get(`/maps/${this.$route.params.id}`);

        this.mode = 'edit';
        this.stepCursor = 5;
        this.steps[5].map = data;

        // The first setContainerSize() above runs before the layout
        // engine has measured anything (clientWidth = 0 in the synchronous
        // mounted body). resize() then multiplies by container.width / size,
        // which is 0/size = 0 — every system circle lands at cx=0,cy=0 and
        // the editor looks empty. After the await + the v-bind data drop,
        // the container has real dimensions; re-measure on the next tick.
        await this.$nextTick();
        this.setContainerSize();
      } catch (err) {
        this.$router.push('/create/maps');
        this.$toastError(this.$t('page.create.map_editor.toast_unknown'));
      }
    }
  },
  beforeDestroy() {
    window.removeEventListener('resize', this.setContainerSize);
    window.removeEventListener('mousemove', this.setMousePosition);
    window.removeEventListener('click', this.onClick);
    window.removeEventListener('keydown', this.onKeydown);
    window.removeEventListener('mousedown', this.onMousedown);
    window.removeEventListener('mouseup', this.onMouseup);
  },
  components: {
    DefaultLayout,
    VueSlider,
  },
};
</script>
