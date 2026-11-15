import { motion } from 'framer-motion'

export default function KpiCard({ label, value, note, icon: Icon, accent = false }) {
  return <motion.article className={`kpi-card ${accent ? 'kpi-accent' : ''}`} initial={{ opacity: 0, y: 8 }} animate={{ opacity: 1, y: 0 }}>
    <div className="kpi-top"><span>{label}</span><span className="kpi-icon"><Icon size={17} strokeWidth={1.8} /></span></div>
    <div className="kpi-value">{value}</div>
    {note && <div className="kpi-note">{note}</div>}
  </motion.article>
}
