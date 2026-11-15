import { ArrowDownRight, ArrowRight, BookOpenCheck, Check, CircleDollarSign, FileCheck2, Layers3, ShieldCheck } from 'lucide-react'
import { Link } from 'react-router-dom'

const capabilities = [
  { icon: BookOpenCheck, title: 'Balanced by design', body: 'Every posted journal records equal debits and credits in PostgreSQL.' },
  { icon: ShieldCheck, title: 'Workspace boundaries', body: 'Records belong to a workspace, with database policies checking access.' },
  { icon: FileCheck2, title: 'Corrections stay visible', body: 'Posted entries remain in the ledger; corrections use compensating entries.' },
]

const workspaces = [
  ['Student', 'Allowances, stipends, expenses and savings goals.'],
  ['Personal', 'A clear record of income, spending and plans.'],
  ['Family', 'Shared household activity with member permissions.'],
  ['Small business', 'Track counterparties, payables, receivables and statements.'],
]

export default function LandingPage() {
  return <div className="public-shell">
    <header className="public-nav">
      <Link className="public-brand" to="/" aria-label="LedgerX home"><span className="brand-mark">L<span>x</span></span><span>ledger<span>x</span></span></Link>
      <nav aria-label="Public navigation"><a href="#how-it-works">How it works</a><a href="#workspaces">Who it serves</a><Link to="/login">Sign in</Link><Link className="button-primary button-small" to="/signup">Create account <ArrowRight size={15} /></Link></nav>
    </header>

    <main>
      <section className="landing-hero">
        <div className="landing-copy">
          <div className="landing-eyebrow"><span /> A careful record for everyday money</div>
          <h1>See your money clearly.<br /><em>Keep every entry accountable.</em></h1>
          <p>LedgerX is being built for people and small teams who want a reliable record of what came in, what went out, and how the numbers reconcile.</p>
          <div className="landing-actions"><Link className="button-primary" to="/signup">Create your workspace <ArrowRight size={16} /></Link><Link className="button-secondary" to="/login">I already have an account</Link></div>
          <div className="landing-assurance"><Check size={15} /><span>Recordkeeping only. No payments, lending or bank credential collection.</span></div>
        </div>
        <div className="ledger-art" aria-label="Illustration of a balanced financial journal">
          <div className="ledger-art-top"><span className="ledger-art-icon"><CircleDollarSign size={20} /></span><span>JOURNAL ENTRY <small>POSTED</small></span><span className="ledger-art-check"><Check size={14} /></span></div>
          <div className="ledger-art-line"><span>Cash account</span><b>Debit</b><strong>Matched</strong></div>
          <div className="ledger-art-line"><span>Allowance income</span><b>Credit</b><strong>Matched</strong></div>
          <div className="ledger-art-rule" />
          <div className="ledger-art-total"><span>Journal difference</span><strong>Zero</strong></div>
          <div className="ledger-art-foot"><ShieldCheck size={15} /><span>Balanced before posting</span><ArrowDownRight size={15} /></div>
          <span className="art-orbit orbit-one" /><span className="art-orbit orbit-two" />
        </div>
        <div className="hero-caption">Illustrative journal · not account activity</div>
      </section>

      <section id="how-it-works" className="capability-section">
        <div className="landing-section-heading"><span>BUILT ON A LEDGER, NOT A GUESS</span><h2>Make the record easy to trust.</h2><p>LedgerX starts with database rules that preserve the history behind each number.</p></div>
        <div className="capability-grid">{capabilities.map(({ icon: Icon, title, body }) => <article className="capability-card" key={title}><span className="capability-icon"><Icon size={19} /></span><h3>{title}</h3><p>{body}</p></article>)}</div>
      </section>

      <section id="workspaces" className="workspace-section">
        <div className="landing-section-heading"><span>ONE PLACE FOR YOUR RECORDS</span><h2>Start with the kind of workspace you need.</h2><p>Choose a workspace during setup. You can manage the records that matter to your situation.</p></div>
        <div className="workspace-categories">{workspaces.map(([name, description], index) => <article className="workspace-category" key={name}><div><span className="category-index">0{index + 1}</span><Layers3 size={17} /></div><h3>{name}</h3><p>{description}</p></article>)}</div>
      </section>

      <section className="privacy-strip"><span className="privacy-mark"><ShieldCheck size={19} /></span><div><strong>Designed for careful financial recordkeeping</strong><p>LedgerX does not move money, hold funds, issue credit, or ask for bank login details. The initial beta is for adults aged 18 and over.</p></div><Link to="/signup">Get started <ArrowRight size={15} /></Link></section>
    </main>
    <footer className="public-footer"><Link className="public-brand" to="/"><span className="brand-mark">L<span>x</span></span><span>ledger<span>x</span></span></Link><span>Educational financial recordkeeping software · Not a payment service</span><span>PostgreSQL-backed</span></footer>
  </div>
}
