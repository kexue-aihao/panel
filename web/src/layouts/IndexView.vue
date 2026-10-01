<script lang="ts" setup>
import HealthBanner from '@/components/system/HealthBanner.vue'
import { useThemeStore } from '@/stores'

import AppMain from './AppMain.vue'
import AppHeader from './header/IndexView.vue'
import SideBar from './sidebar/IndexView.vue'

const themeStore = useThemeStore()

const drawerWidth = computed(() =>
  themeStore.isMobile ? `min(${themeStore.sider.width}px, 82vw)` : themeStore.sider.width,
)

// 平板自动 collapsed
const handleResize = () => {
  const w = window.innerWidth
  if (w < 1024 && w >= 768 && !themeStore.sider.collapsed) {
    themeStore.setCollapsed(true)
  }
}
onMounted(() => {
  handleResize()
  window.addEventListener('resize', handleResize)
})
onBeforeUnmount(() => window.removeEventListener('resize', handleResize))
</script>

<template>
  <n-layout has-sider wh-full class="workspace-shell">
    <n-layout-sider
      v-if="!themeStore.isMobile"
      :collapsed="themeStore.sider.collapsed"
      :collapsed-width="themeStore.sider.collapsedWidth"
      :native-scrollbar="false"
      :width="themeStore.sider.width"
      bordered
      collapse-mode="width"
      class="workspace-sider"
    >
      <side-bar />
    </n-layout-sider>
    <n-drawer
      v-else
      :auto-focus="false"
      :show="!themeStore.sider.collapsed"
      :width="drawerWidth"
      display-directive="show"
      placement="left"
      class="workspace-drawer"
      @mask-click="themeStore.setCollapsed(true)"
    >
      <n-scrollbar>
        <side-bar />
      </n-scrollbar>
    </n-drawer>

    <article class="flex flex-col flex-1 overflow-hidden">
      <header
        :style="`height: ${themeStore.header.height}px`"
        class="workspace-header px-4 flex items-center lg:px-6"
      >
        <app-header />
      </header>
      <health-banner />
      <section class="workspace-content flex flex-col flex-1 overflow-hidden">
        <app-main />
      </section>
    </article>
  </n-layout>
</template>

<style scoped lang="scss">
:deep(.n-scrollbar-content) {
  height: 100%;
}
</style>
