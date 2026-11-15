import { Component } from 'react'
import { AlertTriangle } from 'lucide-react'

export default class ErrorBoundary extends Component {
  constructor(props) { super(props); this.state = { error: null } }
  static getDerivedStateFromError(error) { return { error } }
  render() {
    if (this.state.error) return <div className="fatal-error"><AlertTriangle size={24} /><h2>That view could not be rendered.</h2><p>{this.state.error.message}</p><button onClick={() => window.location.reload()}>Reload this page</button></div>
    return this.props.children
  }
}
