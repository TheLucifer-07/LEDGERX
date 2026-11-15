import { useApi } from '../../hooks/useApi.js'

export default function CurrencySelect({ label, value, onChange }) {
  const result = useApi('/api/v1/currencies')
  return <select aria-label={label} value={value} onChange={(event) => onChange(event.target.value)}>
    <option value="">All currencies</option>
    {(result.data?.items || []).map((currency) => <option key={currency.currency_code} value={currency.currency_code}>{currency.currency_code} · {currency.name}</option>)}
  </select>
}
